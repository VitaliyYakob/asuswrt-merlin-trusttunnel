#!/bin/sh
# Persistent journal + temporary guards. A trial never releases removed sources
# until explicit confirmation. Incomplete rollback keeps the quarantine owned.
tt_transaction_state() {
    if [ -f "$TT_CONFIG/transaction/manifest.json" ]; then
        jq '{id,kind,phase,deadline}' "$TT_CONFIG/transaction/manifest.json"
    else printf 'null\n'; fi
}
tt_transaction_manifest() {
    TT_TX_TMP=$(mktemp "$TT_CONFIG/transaction/.manifest.XXXXXX") || return 1
    jq --arg phase "$1" '.phase=$phase' "$TT_CONFIG/transaction/manifest.json" >"$TT_TX_TMP" &&
        mv -f "$TT_TX_TMP" "$TT_CONFIG/transaction/manifest.json"
}
tt_transaction_guard() {
    tt_transaction_ownership || return 1
    tt_validate policy "$TT_CONFIG/transaction/old-policy.json" &&
        tt_validate policy "$TT_CONFIG/transaction/new-policy.json" || return 1
    TT_TX_PLAN=$(mktemp "$TT_RUN/transaction-plan.XXXXXX") || return 1
    if ! jq -s --arg mode "$1" -f "$TT_BASE/share/quarantine.jq" \
        "$TT_CONFIG/transaction/old-policy.json" "$TT_CONFIG/transaction/new-policy.json" >"$TT_TX_PLAN"; then rm -f "$TT_TX_PLAN"; return 1; fi
    tt_execute_plan "$TT_TX_PLAN"; TT_TX_RESULT=$?
    rm -f "$TT_TX_PLAN"; return "$TT_TX_RESULT"
}
tt_transaction_ownership() {
    # /tmp ownership does not survive reboot. Refuse foreign resources before
    # recovering a persistent journal; its presence alone does not prove ownership.
    [ ! -f "$TT_RUN/transaction-owned" ] || return 0
    tt_claim_resources || return 1
    for TT_TX_CHAIN in TTM4_TXN TTM4_TXNI TTM6_TXN TTM6_TXNI; do
        TT_TX_PROGRAM=iptables; case "$TT_TX_CHAIN" in TTM6*) TT_TX_PROGRAM=ip6tables;; esac
        if "$TT_TX_PROGRAM" -t filter -S "$TT_TX_CHAIN" >/dev/null 2>&1; then
            tt_error 'transaction namespace is occupied'; return 1
        fi
    done
    : >"$TT_RUN/transaction-owned"
}
tt_transaction_cleanup() {
    for TT_TX_FILE in old-policy.json new-policy.json old-endpoint.json new-endpoint.json manifest.json quarantine-owned; do
        rm -f "$TT_CONFIG/transaction/$TT_TX_FILE" || return 1
    done
    rmdir "$TT_CONFIG/transaction" && rm -f "$TT_RUN/transaction-owned"
}
tt_transaction_apply() {
    tt_live && tt_preflight && tt_claim_resources || return 1
    [ ! -e "$TT_CONFIG/transaction" ] || { tt_error 'finish or recover the pending transaction first'; return 1; }
    case "$1" in endpoint|policy) :;; *) return 1;; esac
    # Validate candidate prerequisites before touching traffic or persistent files.
    (if [ "$1" = endpoint ]; then TT_ENDPOINT=$2; else TT_POLICY=$2; fi; tt_preflight) || return 1
    for TT_TX_CHAIN in TTM4_TXN TTM4_TXNI TTM6_TXN TTM6_TXNI; do
        TT_TX_PROGRAM=iptables; case "$TT_TX_CHAIN" in TTM6*) TT_TX_PROGRAM=ip6tables;; esac
        if "$TT_TX_PROGRAM" -t filter -S "$TT_TX_CHAIN" >/dev/null 2>&1; then
            tt_error 'transaction namespace is occupied'; return 1
        fi
    done
    mkdir "$TT_CONFIG/transaction" && chmod 700 "$TT_CONFIG/transaction" || return 1
    if ! cp -p "$TT_POLICY" "$TT_CONFIG/transaction/old-policy.json" ||
        ! cp -p "$TT_ENDPOINT" "$TT_CONFIG/transaction/old-endpoint.json" ||
        ! cp -p "$TT_POLICY" "$TT_CONFIG/transaction/new-policy.json" ||
        ! cp -p "$TT_ENDPOINT" "$TT_CONFIG/transaction/new-endpoint.json" ||
        ! cp "$2" "$TT_CONFIG/transaction/new-$1.json"; then tt_transaction_cleanup; return 1; fi
    TT_TX_PAUSED=false; [ ! -f "$TT_PAUSED" ] || TT_TX_PAUSED=true
    jq -n --arg id "${TT_OP_ID:-local}" --arg kind "$1" --argjson paused "$TT_TX_PAUSED" --argjson deadline "$(($(date +%s)+180))" \
        '{id:$id,kind:$kind,paused:$paused,phase:"prepared",deadline:$deadline}' >"$TT_CONFIG/transaction/manifest.json" || return 1
    : >"$TT_CONFIG/transaction/quarantine-owned"
    : >"$TT_RUN/transaction-owned"
    if tt_transaction_guard block && tt_transaction_manifest applying &&
        tt_transaction_install_new "$1" && tt_transaction_manifest trial && tt_transaction_guard trial; then return 0; fi
    tt_transaction_rollback || tt_error 'rollback incomplete; quarantine retained'
    return 1
}
tt_transaction_install_new() {
    # Existing guards are never removed without the union quarantine in place.
    [ "$1" != endpoint ] || tt_stop_process || return 1
    tt_run_plan disarm "$TT_RUNTIME_POLICY" || return 1
    tt_save_config "$1" "$TT_CONFIG/transaction/new-$1.json" &&
        tt_atomic_json "$TT_POLICY" "$TT_RUNTIME_POLICY" &&
        tt_run_plan guard "$TT_RUNTIME_POLICY" && tt_rpf_loose || return 1
    if [ ! -f "$TT_PAUSED" ]; then tt_spawn || return 1; fi
}
tt_transaction_rollback() {
    tt_live || return 1
    if [ ! -f "$TT_CONFIG/transaction/manifest.json" ]; then
        [ ! -d "$TT_CONFIG/transaction" ] || tt_transaction_cleanup
        return $?
    fi
    # During recovery only the journal's validated policies may own TXN guards.
    [ -f "$TT_CONFIG/transaction/quarantine-owned" ] || { tt_error 'incomplete transaction preparation'; return 1; }
    tt_transaction_manifest recovering && tt_transaction_guard block || return 1
    TT_TX_KIND=$(jq -r .kind "$TT_CONFIG/transaction/manifest.json")
    [ "$TT_TX_KIND" != endpoint ] || tt_stop_process || return 1
    [ ! -f "$TT_RUNTIME_POLICY" ] || tt_run_plan disarm "$TT_RUNTIME_POLICY" || return 1
    tt_atomic_json "$TT_CONFIG/transaction/old-policy.json" "$TT_POLICY" &&
        tt_atomic_json "$TT_CONFIG/transaction/old-endpoint.json" "$TT_ENDPOINT" &&
        tt_revision_advance && tt_atomic_json "$TT_POLICY" "$TT_RUNTIME_POLICY" || return 1
    : >"$TT_OWNED"
    if jq -e .paused "$TT_CONFIG/transaction/manifest.json" >/dev/null; then : >"$TT_PAUSED"; else rm -f "$TT_PAUSED"; fi
    tt_run_plan guard "$TT_RUNTIME_POLICY" && tt_rpf_loose || return 1
    # Recovery can retain protection even when the old server/client is unavailable.
    if [ ! -f "$TT_PAUSED" ]; then tt_preflight && tt_spawn || return 1; fi
    tt_rpf_prune && tt_transaction_guard remove && tt_transaction_cleanup
}
tt_transaction_confirm() {
    [ -f "$TT_CONFIG/transaction/manifest.json" ] || return 1
    jq -e --arg id "$1" --argjson now "$(date +%s)" '.id==$id and .phase=="trial" and .deadline>$now' "$TT_CONFIG/transaction/manifest.json" >/dev/null || return 1
    tt_rpf_prune && tt_transaction_guard remove && tt_transaction_cleanup
}
tt_transaction_reconcile() {
    [ -f "$TT_CONFIG/transaction/manifest.json" ] || return 0
    if jq -e --argjson now "$(date +%s)" '.phase=="trial" and .deadline>$now' "$TT_CONFIG/transaction/manifest.json" >/dev/null; then
        tt_transaction_guard trial
    else tt_transaction_rollback; fi
}
