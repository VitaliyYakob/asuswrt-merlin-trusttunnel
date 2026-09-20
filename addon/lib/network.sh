#!/bin/sh
# No eval, no main-table default-route replacement, no global conntrack flush.
tt_claim_resources() {
    if [ -f "$TT_OWNED" ]; then
        cmp -s "$TT_POLICY" "$TT_RUNTIME_POLICY" || { tt_error 'active policy differs from the owned policy'; return 1; }
        return 0
    fi
    # Refuse to take ownership of a populated table, priority, interface or chain.
    TT_ROUTES=$(ip -4 route show table 871 2>/dev/null) || TT_ROUTES=
    [ -z "$TT_ROUTES" ] || { tt_error 'routing table 871 is already occupied'; return 1; }
    if ip -4 rule show | awk -F: '$1>=17100 && $1<=17131 {found=1} END {exit !found}'; then
        tt_error 'reserved routing priorities are occupied'; return 1
    fi
    if ip link show tt0 >/dev/null 2>&1; then tt_error 'tt0 is already occupied'; return 1; fi
    for TT_CHAIN in TTM4_FWD TTM4_DNS TTM4_SNAT; do
        case "$TT_CHAIN" in TTM4_FWD) TT_TABLE=filter;; *) TT_TABLE=nat;; esac
        if iptables -t "$TT_TABLE" -S "$TT_CHAIN" >/dev/null 2>&1; then
            tt_error 'an IPv4 chain with this namespace already exists'; return 1
        fi
    done
    for TT_CHAIN in TTM6_FWD TTM6_IN; do
        if ip6tables -t filter -S "$TT_CHAIN" >/dev/null 2>&1; then
            tt_error 'an IPv6 chain with this namespace already exists'; return 1
        fi
    done
    tt_atomic_json "$TT_POLICY" "$TT_RUNTIME_POLICY" || return 1
    : >"$TT_OWNED"
}
tt_run_argv() (
    # $1 is a JSON operation generated locally from the validated policy.
    TT_ARGS=$(printf '%s' "$1" | jq -er '.argv[]') || exit 1
    IFS='
'
    set -f
    # Splitting is intentional: validated args contain no CR/LF and no shell code is evaluated.
    # shellcheck disable=SC2086
    set -- $TT_ARGS
    case "$1" in ip) "$@";; *) tt_error 'unsupported planned program'; exit 1;; esac
)
tt_rule() {
    TT_RULE_PREF=$(printf '%s' "$1" | jq -r .priority)
    TT_RULE_SRC=$(printf '%s' "$1" | jq -r .source)
    TT_RULE_IF=$(printf '%s' "$1" | jq -r .interface)
    TT_RULE_TABLE=$(printf '%s' "$1" | jq -r .table)
    # Delete only our exact rule. A remaining priority is a conflict, not ours to delete.
    ip -4 rule del pref "$TT_RULE_PREF" from "$TT_RULE_SRC" iif "$TT_RULE_IF" lookup "$TT_RULE_TABLE" 2>/dev/null || :
    if ip -4 rule show | grep -q "^${TT_RULE_PREF}:"; then
        tt_error 'routing priority conflict'; return 1
    fi
    ip -4 rule add pref "$TT_RULE_PREF" from "$TT_RULE_SRC" iif "$TT_RULE_IF" lookup "$TT_RULE_TABLE"
}
tt_run_plan() {
    TT_PLAN_RAW=$(mktemp "$TT_RUN/plan-raw.XXXXXX") || return 1
    if ! tt_plan "$1" "$2" >"$TT_PLAN_RAW"; then
        rm -f "$TT_PLAN_RAW"; return 1
    fi
    tt_execute_plan "$TT_PLAN_RAW"
    TT_EXEC_RESULT=$?
    rm -f "$TT_PLAN_RAW"
    return "$TT_EXEC_RESULT"
}
tt_execute_plan() {
    # Input must be a locally generated plan, never a browser-supplied document.
    TT_PLAN_TMP=$(mktemp "$TT_RUN/plan.XXXXXX") || return 1
    jq -c '.[]' "$1" >"$TT_PLAN_TMP" || { rm -f "$TT_PLAN_TMP"; return 1; }
    TT_PLAN_OK=1
    while IFS= read -r TT_OP; do
        TT_KIND=$(printf '%s' "$TT_OP" | jq -r .op)
        case "$TT_KIND" in
            command) tt_run_argv "$TT_OP" || { TT_PLAN_OK=0; break; };;
            remove)
                # Missing objects are expected on repeated cleanup. Final disarm is audited below.
                tt_run_argv "$TT_OP" >/dev/null 2>&1 || :;;
            flush-flows)
                TT_FLUSH_BRIDGES=$(printf '%s' "$TT_OP" | jq -er '.interfaces[]') || { TT_PLAN_OK=0; break; }
                for TT_FLUSH_BRIDGE in $TT_FLUSH_BRIDGES; do
                    printf '%s' "$TT_FLUSH_BRIDGE" | grep -Eq '^br[0-9]+(\.[0-9]+)?$' || { TT_PLAN_OK=0; break; }
                    # Flush only selected bridges and their physical members. No
                    # global fc/conntrack flush and no acceleration mode changes.
                    for TT_FLUSH_PATH in "$TT_SYS/class/net/$TT_FLUSH_BRIDGE" "$TT_SYS/class/net/$TT_FLUSH_BRIDGE"/brif/*; do
                        [ -e "$TT_FLUSH_PATH" ] || [ "$TT_FLUSH_PATH" = "$TT_SYS/class/net/$TT_FLUSH_BRIDGE" ] || continue
                        TT_FLUSH_IF=${TT_FLUSH_PATH##*/}
                        printf '%s' "$TT_FLUSH_IF" | grep -Eq '^[a-zA-Z0-9_.:-]{1,15}$' || { TT_PLAN_OK=0; break; }
                        env fc flush --if "$TT_FLUSH_IF" >/dev/null 2>&1 || { TT_PLAN_OK=0; break; }
                    done
                    [ "$TT_PLAN_OK" = 1 ] || break
                done
                if [ "$TT_PLAN_OK" != 1 ]; then TT_FAILURE_CODE=offload_flush_failed; break; fi;;
            rule) tt_rule "$TT_OP" || { TT_PLAN_OK=0; break; };;
            restore)
                TT_PROGRAM=$(printf '%s' "$TT_OP" | jq -r .program)
                case "$TT_PROGRAM" in iptables-restore|ip6tables-restore) :;; *) TT_PLAN_OK=0; break;; esac
                printf '%s' "$TT_OP" | jq -r .stdin | "$TT_PROGRAM" --noflush || { TT_PLAN_OK=0; break; };;
            jump|detach)
                TT_PROGRAM=$(printf '%s' "$TT_OP" | jq -r .program)
                TT_TABLE=$(printf '%s' "$TT_OP" | jq -r .table)
                TT_PARENT=$(printf '%s' "$TT_OP" | jq -r .parent)
                TT_CHAIN=$(printf '%s' "$TT_OP" | jq -r .chain)
                case "$TT_PROGRAM" in iptables|ip6tables) :;; *) TT_PLAN_OK=0; break;; esac
                if [ "$TT_KIND" = jump ]; then
                    # Move a pre-existing jump to the top in one table transaction.
                    # No transient -D/-I window is exposed by separate commands.
                    TT_JUMP_TMP=$(mktemp "$TT_RUN/jump.XXXXXX") || { TT_PLAN_OK=0; break; }
                    printf '*%s\n' "$TT_TABLE" >"$TT_JUMP_TMP"
                    if "$TT_PROGRAM" -t "$TT_TABLE" -C "$TT_PARENT" -j "$TT_CHAIN" 2>/dev/null; then
                        printf '%s\n' "-D $TT_PARENT -j $TT_CHAIN" >>"$TT_JUMP_TMP"
                    fi
                    printf '%s\n' "-I $TT_PARENT 1 -j $TT_CHAIN" 'COMMIT' >>"$TT_JUMP_TMP"
                    if ! "${TT_PROGRAM}-restore" --noflush <"$TT_JUMP_TMP"; then
                        rm -f "$TT_JUMP_TMP"; TT_PLAN_OK=0; break
                    fi
                    rm -f "$TT_JUMP_TMP"
                else
                    TT_TRIES=0
                    while "$TT_PROGRAM" -t "$TT_TABLE" -C "$TT_PARENT" -j "$TT_CHAIN" 2>/dev/null; do
                        "$TT_PROGRAM" -t "$TT_TABLE" -D "$TT_PARENT" -j "$TT_CHAIN" || { TT_PLAN_OK=0; break; }
                        TT_TRIES=$((TT_TRIES+1))
                        [ "$TT_TRIES" -lt 20 ] || { TT_PLAN_OK=0; break; }
                    done
                    "$TT_PROGRAM" -t "$TT_TABLE" -F "$TT_CHAIN" 2>/dev/null || :
                    "$TT_PROGRAM" -t "$TT_TABLE" -X "$TT_CHAIN" 2>/dev/null || :
                fi;;
            *) TT_PLAN_OK=0; break;;
        esac
    done <"$TT_PLAN_TMP"
    rm -f "$TT_PLAN_TMP"
    [ "$TT_PLAN_OK" = 1 ]
}
tt_rpf_loose() {
    TT_RPF_LANS=$(jq -r 'if .schema==1 then .lan_if else .networks[].lan_if end' "$TT_RUNTIME_POLICY") || return 1
    for TT_IF in $TT_RPF_LANS tt0; do
        TT_RPF_FILE="$TT_PROC/sys/net/ipv4/conf/$TT_IF/rp_filter"
        [ -f "$TT_RPF_FILE" ] || continue
        [ -f "$TT_RUN/rpf-$TT_IF" ] || cat "$TT_RPF_FILE" >"$TT_RUN/rpf-$TT_IF"
        printf '2\n' >"$TT_RPF_FILE" || return 1
    done
}
tt_rpf_restore() {
    for TT_SAVED in "$TT_RUN"/rpf-*; do
        [ -f "$TT_SAVED" ] || continue
        TT_IF=${TT_SAVED##*/rpf-}
        TT_RPF_FILE="$TT_PROC/sys/net/ipv4/conf/$TT_IF/rp_filter"
        if [ -f "$TT_RPF_FILE" ] && [ "$(cat "$TT_RPF_FILE")" = 2 ]; then
            cat "$TT_SAVED" >"$TT_RPF_FILE" || return 1
        fi
        rm -f "$TT_SAVED"
    done
}
tt_rpf_prune() {
    # A confirmed migration no longer owns rp_filter on bridges it stopped using.
    TT_RPF_KEEP=$(jq -r 'if .schema==1 then .lan_if else .networks[].lan_if end' "$TT_RUNTIME_POLICY") || return 1
    for TT_SAVED in "$TT_RUN"/rpf-*; do
        [ -f "$TT_SAVED" ] || continue
        TT_IF=${TT_SAVED##*/rpf-}
        [ "$TT_IF" != tt0 ] || continue
        if printf '%s\n' "$TT_RPF_KEEP" | grep -Fxq "$TT_IF"; then continue; fi
        TT_RPF_FILE="$TT_PROC/sys/net/ipv4/conf/$TT_IF/rp_filter"
        if [ -f "$TT_RPF_FILE" ] && [ "$(cat "$TT_RPF_FILE")" = 2 ]; then
            cat "$TT_SAVED" >"$TT_RPF_FILE" || return 1
        fi
        rm -f "$TT_SAVED" || return 1
    done
}
tt_disarm() {
    [ -f "$TT_OWNED" ] || return 0
    tt_run_plan disarm "$TT_RUNTIME_POLICY" || return 1
    # Never report successful removal while owned resources remain.
    if ip -4 rule show | awk -F: '$1>=17100 && $1<=17131 {f=1} END {exit !f}'; then
        tt_error 'routing rules remain; ownership retained'; return 1
    fi
    TT_LEFT=$(ip -4 route show table 871 2>/dev/null) || TT_LEFT=
    [ -z "$TT_LEFT" ] || { tt_error 'routing table is not empty; ownership retained'; return 1; }
    for TT_CHAIN in TTM4_FWD TTM4_DNS TTM4_SNAT; do
        case "$TT_CHAIN" in TTM4_FWD) TT_TABLE=filter;; *) TT_TABLE=nat;; esac
        if iptables -t "$TT_TABLE" -S "$TT_CHAIN" >/dev/null 2>&1; then return 1; fi
    done
    for TT_CHAIN in TTM6_FWD TTM6_IN; do
        if ip6tables -t filter -S "$TT_CHAIN" >/dev/null 2>&1; then return 1; fi
    done
    tt_rpf_restore || return 1
    rm -f "$TT_OWNED" "$TT_RUNTIME_POLICY"
}
