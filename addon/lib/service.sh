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
    TT_LANS=$(jq -r 'if .schema==1 then .lan_if else .networks[].lan_if,.ports[]?.lan_if end' "$TT_POLICY") || return 1
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
    for TT_TOOL in jq ip iptables ip6tables iptables-restore ip6tables-restore flock sha256sum mkfifo; do
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
    tt_ports_check || { tt_start_failure ports_unavailable 'selected LAN ports are unavailable or marking conflicts with another policy'; return 1; }
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
    # A bounded consumer keeps logs in RAM below 1 MiB even if refresh stalls.
    # Both children close the control FD; EOF cleans the unique owned FIFO.
    type mkfifo >/dev/null 2>&1 || { tt_error 'mkfifo is required'; return 1; }
    TT_LOG_DIR=$(mktemp -d "$TT_RUN/.log.XXXXXX") || return 1
    if ! mkfifo -m 600 "$TT_LOG_DIR/pipe"; then rmdir "$TT_LOG_DIR"; return 1; fi
    /bin/sh "$TT_BASE/lib/log-writer.sh" "$TT_LOG_DIR" "$TT_RUN/client.log" </dev/null >/dev/null 2>&1 9>&- &
    "$TT_BIN" --config "$TT_RUN/client.toml" >"$TT_LOG_DIR/pipe" 2>&1 9>&- &
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
    if type tt_update_recover >/dev/null 2>&1; then tt_update_recover || return 1; fi
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
    if type tt_update_recover >/dev/null 2>&1; then tt_update_recover || return 1; fi
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
        if [ "$(tt_timer_remaining "$TT_RUN/retry.json")" -gt 0 ]; then return 1; fi
    fi
    if tt_preflight && tt_spawn; then rm -f "$TT_RUN/retry.json"; return 0; fi
    TT_RETRY_COUNT=$((TT_RETRY_COUNT+1)); [ "$TT_RETRY_COUNT" -le 5 ] || TT_RETRY_COUNT=5
    TT_RETRY_DELAY=60; TT_RETRY_I=1
    while [ "$TT_RETRY_I" -lt "$TT_RETRY_COUNT" ]; do TT_RETRY_DELAY=$((TT_RETRY_DELAY*2)); TT_RETRY_I=$((TT_RETRY_I+1)); done
    [ "$TT_RETRY_DELAY" -le 900 ] || TT_RETRY_DELAY=900
    TT_RETRY_TIMER=$(tt_timer "$TT_RETRY_DELAY") || return 1
    jq -n --argjson timer "$TT_RETRY_TIMER" --argjson failures "$TT_RETRY_COUNT" --argjson next "$(($(date +%s)+TT_RETRY_DELAY))" \
        '{failures:$failures,next_attempt:$next,timer:$timer}' >"$TT_RUN/retry.json"
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
# Linux exports USER_HZ as AT_CLKTCK; do not assume CONFIG_HZ or wall time.
tt_client_uptime() (
    tt_pid_matches || { printf 'null\n'; return; }
    hz=$(od -An -v -tu8 "$TT_PROC/self/auxv" 2>/dev/null | awk '$1==17 {print $2; exit}')
    up=$(tt_uptime) || { printf 'null\n'; return; }
    case "$hz:$TT_START:$up" in *[!0-9:]*|:*|*::*|*:) printf 'null\n'; return;; esac
    awk -v hz="$hz" -v ticks="$TT_START" -v up="$up" 'BEGIN {if(hz>0 && up>=ticks/hz) print int(up-ticks/hz); else print "null"}'
)
tt_process_metrics() (
    tt_pid_matches || { printf 'null\n'; return; }
    [ -r "$TT_PROC/$TT_PID/status" ] && [ -r "$TT_PROC/$TT_PID/stat" ] && [ -r "$TT_PROC/stat" ] || { printf 'null\n'; return; }
    # /proc entries can disappear between the identity check and the read.
    # Optional metrics must never prevent core status publication after a crash.
    if ! { rss=$(awk '$1=="VmRSS:" {print $2; found=1; exit} END {if(!found)print 0}' "$TT_PROC/$TT_PID/status" 2>/dev/null) &&
        ticks=$(awk '{printf "%.0f\n",$14+$15}' "$TT_PROC/$TT_PID/stat" 2>/dev/null) &&
        system=$(awk '$1=="cpu" {for(i=2;i<=9;i++)total+=$i; printf "%.0f\n",total; exit}' "$TT_PROC/stat" 2>/dev/null) &&
        cores=$(awk '/^cpu[0-9]+ / {n++} END {print n+0}' "$TT_PROC/stat" 2>/dev/null); }; then printf 'null\n'; return; fi
    case "$rss:$ticks:$system:$cores" in *[!0-9:]*|:*|*::*) printf 'null\n'; return;; esac
    jq -n --arg start "$TT_START" --argjson rss "$rss" --argjson ticks "$ticks" --argjson system "$system" --argjson cores "$cores" \
        '{process_start:$start,rss_kib:$rss,cpu_ticks:$ticks,system_ticks:$system,cpu_count:$cores}'
)
tt_status_details() {
    TT_DETAILS_READY=true; TT_DETAILS_ERROR=
    TT_DISCOVERED_NETWORKS=$(tt_discover_networks) || {
        TT_DISCOVERED_NETWORKS='[]'; TT_DETAILS_READY=false; TT_DETAILS_ERROR=inventory_unavailable;
    }
    TT_NETWORK_WARNINGS=$(tt_network_warnings) || TT_NETWORK_WARNINGS='[]'
    TT_STATUS_PORTS=$(tt_port_inventory) || TT_STATUS_PORTS='[]'
    TT_STATUS_CLIENTS='[]'; TT_STATUS_DIAG='{}'
    if type tt_client_inventory >/dev/null 2>&1; then TT_STATUS_CLIENTS=$(tt_client_inventory) || TT_STATUS_CLIENTS='[]'; fi
    if type tt_diagnostics >/dev/null 2>&1; then TT_STATUS_DIAG=$(tt_diagnostics) || TT_STATUS_DIAG='{}'; fi
    TT_TUN_ADDRESSES='[]'; TT_STATUS_UPDATES='{}'; TT_STATUS_OBSERVATION=null
    if type tt_tunnel_addresses >/dev/null 2>&1; then TT_TUN_ADDRESSES=$(tt_tunnel_addresses) || TT_TUN_ADDRESSES='[]'; fi
    if type tt_update_status >/dev/null 2>&1; then TT_STATUS_UPDATES=$(tt_update_status) || TT_STATUS_UPDATES='{}'; fi
    if type tt_observation_status >/dev/null 2>&1; then TT_STATUS_OBSERVATION=$(tt_observation_status) || TT_STATUS_OBSERVATION=null; fi
    if [ -f "$TT_RUN/nvram-failed" ]; then TT_DETAILS_READY=false; TT_DETAILS_ERROR=nvram_unavailable; fi
    jq -n --argjson ports "$TT_STATUS_PORTS" --argjson available "$TT_DETAILS_READY" --arg error "$TT_DETAILS_ERROR" \
        --argjson discovered_networks "$TT_DISCOVERED_NETWORKS" --argjson network_warnings "$TT_NETWORK_WARNINGS" \
        --argjson clients "$TT_STATUS_CLIENTS" --argjson diagnostics "$TT_STATUS_DIAG" \
        --argjson tunnel_addresses "$TT_TUN_ADDRESSES" --argjson client_updates "$TT_STATUS_UPDATES" --argjson traffic_observation "$TT_STATUS_OBSERVATION" \
        '{available:$available,error:$error,ports:$ports,discovered_networks:$discovered_networks,network_warnings:$network_warnings,
          clients:$clients,diagnostics:$diagnostics,tunnel_addresses:$tunnel_addresses,client_updates:$client_updates,traffic_observation:$traffic_observation}'
}
tt_read_status_details() (
    # Only read-only collection runs in this process group. A timeout must never
    # kill a configuration transaction, client process or firewall operation.
    exec 9>&-
    type timeout >/dev/null 2>&1 || return 1
    umask 077
    output=$(mktemp "$TT_RUN/.status-details.XXXXXX") || return 1
    trap 'rm -f "$output"' EXIT
    # A timed-out descendant must not keep a command-substitution pipe open.
    timeout -k 1 15 "$TT_BASE/trusttunnel.sh" status-details >"$output" 2>/dev/null || return 1
    cat "$output"
)
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
        TT_PUBLIC_ENDPOINT=$(jq -c '{configured:true,exclusions:(.exclusions//[]),settings:{protocol,mtu,anti_dpi}}' "$TT_ENDPOINT" 2>/dev/null) || TT_PUBLIC_ENDPOINT='{"configured":false,"exclusions":[]}'
    fi
    TT_PUBLIC_POLICY=null
    [ ! -f "$TT_POLICY" ] || TT_PUBLIC_POLICY=$(jq -c . "$TT_POLICY" 2>/dev/null)
    TT_ENABLED_JSON=false
    [ ! -f "$TT_ENABLED" ] || TT_ENABLED_JSON=true
    TT_LAST=none
    [ ! -f "$TT_RUN/last-result" ] || TT_LAST=$(cat "$TT_RUN/last-result")
    TT_STATUS_OPS=$(tt_operations_json) || TT_STATUS_OPS='[]'
    TT_STATUS_TX=null
    if type tt_transaction_state >/dev/null 2>&1; then TT_STATUS_TX=$(tt_transaction_state) || TT_STATUS_TX=null; fi
    TT_STATUS_DETAILS=$(tt_read_status_details) || TT_STATUS_DETAILS='{"available":false,"error":"details_unavailable"}'
    if ! printf '%s' "$TT_STATUS_DETAILS" | jq -e 'type=="object" and (.available|type=="boolean")' >/dev/null 2>&1; then
        TT_STATUS_DETAILS='{"available":false,"error":"details_unavailable"}'
    fi
    jq -n --argjson details "$TT_STATUS_DETAILS" --arg version "$TT_VERSION" --arg state "$TT_STATE" --arg hostname "$TT_HOST" \
        --arg last_result "$TT_LAST" --argjson process_running "$TT_PROCESS" --argjson interface_up "$TT_TUN" \
        --argjson enabled "$TT_ENABLED_JSON" --argjson rx "$TT_RX" --argjson tx "$TT_TX" \
        --argjson policy "$TT_PUBLIC_POLICY" --argjson timestamp "$(date +%s)" \
        --arg revision "$(tt_revision)" --argjson operations "$TT_STATUS_OPS" --argjson transaction "$TT_STATUS_TX" \
        --argjson endpoint "$TT_PUBLIC_ENDPOINT" --argjson metrics "$(tt_process_metrics)" --argjson client_uptime_seconds "$(tt_client_uptime)" \
        '{version:$version,state:$state,hostname:$hostname,enabled:$enabled,process_running:$process_running,
          interface_up:$interface_up,tunnel_addresses:($details.tunnel_addresses//[]),client_updates:($details.client_updates//{}),
          connection_verified:false,client_uptime_seconds:$client_uptime_seconds,traffic_observation:($details.traffic_observation//null),metrics:$metrics,rx_bytes:$rx,tx_bytes:$tx,endpoint:$endpoint,
          policy:$policy,ports:($details.ports//[]),discovered_networks:($details.discovered_networks//[]),network_warnings:($details.network_warnings//[]),
          timestamp:$timestamp,last_result:$last_result,hardware_tested:false,revision:$revision,operations:$operations,
          transaction:$transaction,clients:($details.clients//[]),diagnostics:($details.diagnostics//{}),
          health:{details_ready:$details.available,error:($details.error//"")}}'
}
tt_publish_status() {
    if type tt_transfer_expire >/dev/null 2>&1; then tt_transfer_expire || :; fi
    if type tt_observe_traffic >/dev/null 2>&1; then tt_observe_traffic || :; fi
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
