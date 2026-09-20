#!/bin/sh
# shellcheck source=inventory.sh
. "$TT_BASE/lib/inventory.sh"
# shellcheck source=compatibility.sh
. "$TT_BASE/lib/compatibility.sh"
tt_check_interfaces() {
    if [ "$(jq -r .schema "$TT_POLICY")" -eq 4 ]; then
        TT_CURRENT_NETWORKS=$(tt_discover_networks) || return 1
        jq -e --argjson inventory "$TT_CURRENT_NETWORKS" '
            all(.networks[]; . as $n | any($inventory[]; .lan_if==$n.lan_if and
                (($n|has("identity")|not) or .identity==$n.identity))) and
            all(.local_access[]; . as $n | any($inventory[]; .lan_if==$n.lan_if and .identity==$n.identity and
                (.sources|index($n.destination))!=null))' "$TT_POLICY" >/dev/null || {
            tt_error 'network topology changed; review networks and local exceptions'; return 1;
        }
    fi
    TT_LANS=$(jq -r 'if .schema==1 then .lan_if else .networks[].lan_if end' "$TT_POLICY") || return 1
    for TT_LAN in $TT_LANS; do
        [ -d "$TT_SYS/class/net/$TT_LAN/bridge" ] || { tt_error 'configured LAN bridge does not exist'; return 1; }
    done
    TT_WAN=$(jq -r .wan_if "$TT_ENDPOINT")
    if [ -n "$TT_WAN" ]; then
        for TT_LAN in $TT_LANS; do
            [ "$TT_WAN" != "$TT_LAN" ] || { tt_error 'WAN interface is a selected LAN bridge'; return 1; }
        done
        [ "$TT_WAN" != tt0 ] && ip link show "$TT_WAN" >/dev/null 2>&1 || {
            tt_error 'configured WAN interface is invalid'; return 1;
        }
    fi
}
tt_check_dns_transit() {
    # This is an internal DNAT destination, never a configured DNS resolver.
    [ -z "$TT_ROOT" ] || { tt_error 'live address checks are prohibited with TT_ROOT'; return 1; }
    TT_DNS_LOCAL_ADDRS=$(ip -4 -o addr show 2>/dev/null) || {
        tt_error 'cannot check internal DNS transit address'; return 1;
    }
    if printf '%s\n' "$TT_DNS_LOCAL_ADDRS" | awk '$3=="inet" && $4 ~ /^192[.]0[.]2[.]53\// {found=1} END {exit !found}'; then
        tt_error 'internal DNS transit address conflicts with a local interface'; return 1
    fi
}
tt_preflight() {
    TT_FAILURE_CODE=
    tt_live || return 1
    for TT_TOOL in jq ip iptables ip6tables iptables-restore ip6tables-restore flock sha256sum; do
        type "$TT_TOOL" >/dev/null 2>&1 || { tt_start_failure missing_dependency 'required runtime tool missing'; return 1; }
    done
    tt_validate endpoint "$TT_ENDPOINT" || { tt_start_failure endpoint_missing 'save a valid connection first'; return 1; }
    tt_validate policy "$TT_POLICY" || { tt_start_failure policy_missing 'select and save routing networks first'; return 1; }
    [ -x "$TT_BIN" ] || { tt_start_failure client_missing 'install a verified TrustTunnel client binary first'; return 1; }
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || { tt_start_failure forwarding_disabled 'IPv4 forwarding is disabled'; return 1; }
    tt_require_dns || { tt_start_failure dns_missing 'connection has no DNS upstreams'; return 1; }
    tt_check_dns_transit || { tt_start_failure dns_conflict 'DNS transit address cannot be used'; return 1; }
    tt_check_interfaces || { tt_start_failure network_changed 'saved network topology is no longer available'; return 1; }
    tt_selective_offload_supported || {
        tt_start_failure offload_unavailable 'firmware needs IPv4/IPv6 SKIPLOG and per-interface flow cache control'; return 1;
    }
    tt_ensure_tun
}
tt_stop_process() {
    if tt_pid_matches; then
        kill -TERM "$TT_PID" || return 1
        TT_N=0
        while tt_pid_matches && [ "$TT_N" -lt 10 ]; do sleep 1; TT_N=$((TT_N+1)); done
        if tt_pid_matches; then kill -KILL "$TT_PID" || return 1; sleep 1; fi
        tt_pid_matches && { tt_error 'client did not stop'; return 1; }
    fi
    rm -f "$TT_RUN/client.pid" "$TT_RUN/client.start" "$TT_RUN/client.started"
    [ ! -f "$TT_OWNED" ] || tt_run_plan down "$TT_RUNTIME_POLICY"
}
tt_spawn() {
    if tt_pid_matches; then
        # A firewall/WAN event may have removed routes without killing the process.
        ip link show tt0 >/dev/null 2>&1 || { tt_error 'owned process has no TUN interface'; return 1; }
        tt_rpf_loose && tt_run_plan up "$TT_RUNTIME_POLICY"
        return $?
    fi
    # Do not attach to an interface possibly owned by another process.
    if ip link show tt0 >/dev/null 2>&1; then tt_error 'tt0 exists without a matching owned process'; return 1; fi
    tt_render_runtime || return 1
    : >"$TT_RUN/client.log"
    chmod 600 "$TT_RUN/client.log"
    # Close the controller lock FD in the child. Retaining it would deadlock future actions.
    "$TT_BIN" --config "$TT_RUN/client.toml" >>"$TT_RUN/client.log" 2>&1 9>&- &
    TT_NEW_PID=$!
    printf '%s\n' "$TT_NEW_PID" >"$TT_RUN/client.pid"
    [ -r "$TT_PROC/$TT_NEW_PID/stat" ] || { tt_error 'client exited before PID registration'; return 1; }
    awk '{print $22}' "$TT_PROC/$TT_NEW_PID/stat" >"$TT_RUN/client.start"
    date +%s >"$TT_RUN/client.started"
    TT_N=0
    while [ "$TT_N" -lt 10 ]; do
        tt_pid_matches || { tt_error 'client exited; protection retained'; return 1; }
        if ip link show tt0 >/dev/null 2>&1; then
            tt_rpf_loose && tt_run_plan up "$TT_RUNTIME_POLICY" || return 1
            return 0
        fi
        sleep 1; TT_N=$((TT_N+1))
    done
    tt_error 'TUN did not appear; protection retained'
    return 1
}
tt_start() {
    rm -f "$TT_RUN/retry.json"
    tt_preflight && tt_claim_resources || return 1
    # Remember intent before constructing rules. A failed start is not a silent disable.
    : >"$TT_ENABLED"
    rm -f "$TT_PAUSED"
    tt_run_plan guard "$TT_RUNTIME_POLICY" && tt_rpf_loose && tt_spawn
}
tt_pause() {
    [ -f "$TT_ENABLED" ] || return 0
    : >"$TT_PAUSED"
    tt_stop_process
}
tt_disable() {
    # Explicit disable intentionally releases fail-closed policy.
    tt_stop_process && tt_disarm || return 1
    rm -f "$TT_ENABLED" "$TT_PAUSED"
}
tt_refresh() {
    [ -f "$TT_ENABLED" ] || return 0
    # Rebuild requested guards independently of client/endpoint availability.
    # A firewall callback can arrive after firmware removed the previous rules.
    tt_live || return 1
    if type tt_transaction_reconcile >/dev/null 2>&1; then tt_transaction_reconcile || return 1; fi
    tt_validate policy "$TT_POLICY" && tt_claim_resources &&
        tt_run_plan guard "$TT_RUNTIME_POLICY" && tt_rpf_loose || return 1
    if [ -f "$TT_PAUSED" ]; then tt_stop_process; else tt_retry_client; fi
    TT_REFRESH_RESULT=$?
    if type tt_transaction_reconcile >/dev/null 2>&1; then tt_transaction_reconcile || return 1; fi
    return "$TT_REFRESH_RESULT"
}
tt_retry_client() {
    # Guards have already been restored. Backoff never releases protection.
    TT_RETRY_COUNT=0
    if [ -f "$TT_RUN/retry.json" ]; then
        TT_RETRY_COUNT=$(jq -r '.failures' "$TT_RUN/retry.json") || return 1
        if jq -e --argjson now "$(date +%s)" '.next_attempt>$now' "$TT_RUN/retry.json" >/dev/null; then return 1; fi
    fi
    if tt_preflight && tt_spawn; then rm -f "$TT_RUN/retry.json"; return 0; fi
    TT_RETRY_COUNT=$((TT_RETRY_COUNT+1)); [ "$TT_RETRY_COUNT" -le 5 ] || TT_RETRY_COUNT=5
    TT_RETRY_DELAY=60; TT_RETRY_I=1
    while [ "$TT_RETRY_I" -lt "$TT_RETRY_COUNT" ]; do TT_RETRY_DELAY=$((TT_RETRY_DELAY*2)); TT_RETRY_I=$((TT_RETRY_I+1)); done
    [ "$TT_RETRY_DELAY" -le 900 ] || TT_RETRY_DELAY=900
    jq -n --argjson failures "$TT_RETRY_COUNT" --argjson next "$(($(date +%s)+TT_RETRY_DELAY))" \
        '{failures:$failures,next_attempt:$next}' >"$TT_RUN/retry.json"
    return 1
}
tt_limit_log() {
    [ -f "$TT_RUN/client.log" ] || return 0
    TT_LOG_SIZE=$(wc -c <"$TT_RUN/client.log")
    if [ "$TT_LOG_SIZE" -gt 1048576 ]; then
        tail -c 131072 "$TT_RUN/client.log" >"$TT_RUN/log.tail" &&
            cat "$TT_RUN/log.tail" >"$TT_RUN/client.log"
        rm -f "$TT_RUN/log.tail"
    fi
}
tt_status() {
    TT_PROCESS=false; TT_TUN=false; TT_STATE=disabled
    tt_pid_matches && TT_PROCESS=true
    [ -d "$TT_SYS/class/net/tt0" ] && TT_TUN=true
    if [ -f "$TT_ENABLED" ]; then
        TT_STATE=blocked_or_start_failed
        [ -f "$TT_PAUSED" ] && TT_STATE=paused_protected
        if [ "$TT_PROCESS" = true ] && [ "$TT_TUN" = true ] && [ ! -f "$TT_PAUSED" ]; then
            TT_STATE=tun_ready_unverified
        fi
    fi
    TT_RX=0; TT_TX=0
    [ ! -r "$TT_SYS/class/net/tt0/statistics/rx_bytes" ] || TT_RX=$(cat "$TT_SYS/class/net/tt0/statistics/rx_bytes")
    [ ! -r "$TT_SYS/class/net/tt0/statistics/tx_bytes" ] || TT_TX=$(cat "$TT_SYS/class/net/tt0/statistics/tx_bytes")
    TT_HOST=
    [ ! -f "$TT_ENDPOINT" ] || TT_HOST=$(jq -r '.hostname // ""' "$TT_ENDPOINT" 2>/dev/null)
    TT_PUBLIC_ENDPOINT='{"configured":false,"exclusions":[]}'
    if [ -f "$TT_ENDPOINT" ] && [ ! -L "$TT_ENDPOINT" ]; then
        TT_PUBLIC_ENDPOINT=$(jq -c '{configured:true,exclusions:(.exclusions//[])}' "$TT_ENDPOINT" 2>/dev/null) || TT_PUBLIC_ENDPOINT='{"configured":false,"exclusions":[]}'
    fi
    TT_PUBLIC_POLICY=null
    [ ! -f "$TT_POLICY" ] || TT_PUBLIC_POLICY=$(jq -c . "$TT_POLICY" 2>/dev/null)
    TT_ENABLED_JSON=false
    [ ! -f "$TT_ENABLED" ] || TT_ENABLED_JSON=true
    TT_LAST=none
    [ ! -f "$TT_RUN/last-result" ] || TT_LAST=$(cat "$TT_RUN/last-result")
    TT_DISCOVERED_NETWORKS=$(tt_discover_networks) || TT_DISCOVERED_NETWORKS='[]'
    TT_NETWORK_WARNINGS=$(tt_network_warnings) || TT_NETWORK_WARNINGS='[]'
    TT_STATUS_OPS=$(tt_operations_json) || TT_STATUS_OPS='[]'
    TT_STATUS_TX=null
    if type tt_transaction_state >/dev/null 2>&1; then TT_STATUS_TX=$(tt_transaction_state) || TT_STATUS_TX=null; fi
    TT_STATUS_CLIENTS='[]'; TT_STATUS_DIAG='{}'
    if type tt_client_inventory >/dev/null 2>&1; then TT_STATUS_CLIENTS=$(tt_client_inventory) || TT_STATUS_CLIENTS='[]'; fi
    if type tt_diagnostics >/dev/null 2>&1; then TT_STATUS_DIAG=$(tt_diagnostics) || TT_STATUS_DIAG='{}'; fi
    jq -n --arg version "$TT_VERSION" --arg state "$TT_STATE" --arg hostname "$TT_HOST" \
        --arg last_result "$TT_LAST" --argjson process_running "$TT_PROCESS" --argjson interface_up "$TT_TUN" \
        --argjson enabled "$TT_ENABLED_JSON" --argjson rx "$TT_RX" --argjson tx "$TT_TX" \
        --argjson policy "$TT_PUBLIC_POLICY" --argjson discovered_networks "$TT_DISCOVERED_NETWORKS" --argjson timestamp "$(date +%s)" \
        --arg revision "$(tt_revision)" --argjson operations "$TT_STATUS_OPS" --argjson transaction "$TT_STATUS_TX" \
        --argjson clients "$TT_STATUS_CLIENTS" --argjson diagnostics "$TT_STATUS_DIAG" --argjson endpoint "$TT_PUBLIC_ENDPOINT" --argjson network_warnings "$TT_NETWORK_WARNINGS" \
        '{version:$version,state:$state,hostname:$hostname,enabled:$enabled,process_running:$process_running,
          interface_up:$interface_up,connection_verified:false,rx_bytes:$rx,tx_bytes:$tx,endpoint:$endpoint,
          policy:$policy,discovered_networks:$discovered_networks,network_warnings:$network_warnings,timestamp:$timestamp,last_result:$last_result,hardware_tested:false,
          revision:$revision,operations:$operations,transaction:$transaction,clients:$clients,diagnostics:$diagnostics}'
}
tt_publish_status() {
    if type tt_transfer_expire >/dev/null 2>&1; then tt_transfer_expire || :; fi
    tt_limit_log
    TT_STATUS_TMP=$(mktemp "$TT_RUN/status.XXXXXX") || return 1
    if tt_status >"$TT_STATUS_TMP"; then
        mv -f "$TT_STATUS_TMP" "$TT_RUN/status.json" || return 1
        if [ -d "$TT_PUBLIC" ]; then
            cp "$TT_RUN/status.json" "$TT_PUBLIC/status.json.tmp" &&
                chmod 644 "$TT_PUBLIC/status.json.tmp" && mv -f "$TT_PUBLIC/status.json.tmp" "$TT_PUBLIC/status.json"
        fi
    else rm -f "$TT_STATUS_TMP"; return 1; fi
}
