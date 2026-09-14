#!/bin/sh
tt_preflight() {
    tt_live || return 1
    for TT_TOOL in jq ip iptables ip6tables iptables-restore ip6tables-restore flock sha256sum; do
        command -v "$TT_TOOL" >/dev/null 2>&1 || { tt_error "required tool missing: $TT_TOOL"; return 1; }
    done
    [ -c /dev/net/tun ] || { tt_error 'TUN device is unavailable'; return 1; }
    [ -x "$TT_BIN" ] || { tt_error 'install a verified TrustTunnel client binary first'; return 1; }
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || { tt_error 'IPv4 forwarding is disabled'; return 1; }
    tt_validate endpoint "$TT_ENDPOINT" && tt_validate policy "$TT_POLICY" || return 1
    TT_LAN=$(jq -r .lan_if "$TT_POLICY")
    [ -d "/sys/class/net/$TT_LAN/bridge" ] || { tt_error 'configured LAN bridge does not exist'; return 1; }
    TT_WAN=$(jq -r .wan_if "$TT_ENDPOINT")
    if [ -n "$TT_WAN" ]; then
        [ "$TT_WAN" != "$TT_LAN" ] && [ "$TT_WAN" != tt0 ] && ip link show "$TT_WAN" >/dev/null 2>&1 || {
            tt_error 'configured WAN interface is invalid'; return 1;
        }
    fi
    # Lab-only: this acknowledgement does not prove acceleration is actually disabled.
    # ctf_disable is checked; HND runner/flow-cache verification is a hardware test gate.
    [ "$(nvram get ctf_disable)" = 1 ] || {
        tt_error 'disable NAT acceleration for alpha testing (ctf_disable must be 1)'; return 1;
    }
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
    tt_preflight && tt_claim_resources && tt_run_plan guard "$TT_RUNTIME_POLICY" && tt_rpf_loose || return 1
    if [ -f "$TT_PAUSED" ]; then tt_stop_process; else tt_spawn; fi
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
    TT_PUBLIC_POLICY=null
    [ ! -f "$TT_POLICY" ] || TT_PUBLIC_POLICY=$(jq -c . "$TT_POLICY" 2>/dev/null)
    TT_ENABLED_JSON=false
    [ ! -f "$TT_ENABLED" ] || TT_ENABLED_JSON=true
    TT_LAST=none
    [ ! -f "$TT_RUN/last-result" ] || TT_LAST=$(cat "$TT_RUN/last-result")
    jq -n --arg version "$TT_VERSION" --arg state "$TT_STATE" --arg hostname "$TT_HOST" \
        --arg last_result "$TT_LAST" --argjson process_running "$TT_PROCESS" --argjson interface_up "$TT_TUN" \
        --argjson enabled "$TT_ENABLED_JSON" --argjson rx "$TT_RX" --argjson tx "$TT_TX" \
        --argjson policy "$TT_PUBLIC_POLICY" --argjson timestamp "$(date +%s)" \
        '{version:$version,state:$state,hostname:$hostname,enabled:$enabled,process_running:$process_running,
          interface_up:$interface_up,connection_verified:false,rx_bytes:$rx,tx_bytes:$tx,
          policy:$policy,timestamp:$timestamp,last_result:$last_result,hardware_tested:false}'
}
tt_publish_status() {
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
