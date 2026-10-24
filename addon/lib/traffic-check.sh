#!/bin/sh
# Observes actual LAN forwarding, sends no probes and changes no network state.
tt_tunnel_addresses() {
    [ -z "$TT_ROOT" ] || { printf '[]\n'; return; }
    ip -4 -o addr show dev tt0 2>/dev/null | awk '$3=="inet" {print $4}' |
        jq -Rs 'split("\n")|map(select(test("^[0-9.]+/[0-9]{1,2}$")))'
}
tt_check_guard_rules() (
    tt_validate policy "$TT_POLICY" && [ -f "$TT_OWNED" ] && cmp -s "$TT_POLICY" "$TT_RUNTIME_POLICY" || return 1
    plan=$(tt_plan guard "$TT_RUNTIME_POLICY") || return 1
    # Check every generated firewall rule, not just presence of named chains.
    rules=$(printf '%s' "$plan" | jq -c '.[]|select(.op=="restore")') || return 1
    while IFS= read -r rule; do
        program=$(printf '%s' "$rule" | jq -r '.program|sub("-restore$";"")')
        table=$(printf '%s' "$rule" | jq -r '.stdin|split("\n")[0]|.[1:]')
        lines=$(printf '%s' "$rule" | jq -r '.stdin|split("\n")[]|select(startswith("-A "))|sub("^-A ";"-C ")')
        while IFS= read -r line; do
            set -f
            # Validated policy fields cannot contain spaces/newlines or options.
            # shellcheck disable=SC2086
            "$program" -t "$table" $line >/dev/null 2>&1 || return 1
        done <<EOF
$lines
EOF
    done <<EOF
$rules
EOF
    if jq -e '((.ports//[])|length)>0' "$TT_RUNTIME_POLICY" >/dev/null; then tt_ports_integrity || return 1; fi
    [ "$(tt_guard_state)" = installed_unverified ] || return 1
    ip -4 route show table 871 | grep -Eq '^default dev tt0( |$)' || return 1
    actual=$(ip -4 rule show | awk '{$1=$1; print}') || return 1
    expected=$(printf '%s' "$plan" | jq -r '.[]|select(.op=="rule")|"\(.priority): from \((.source|sub("/32$";""))) iif \(.interface) lookup \(.table)"')
    while IFS= read -r line; do printf '%s\n' "$actual" | grep -Fxq "$line" || return 1; done <<EOF
$expected
EOF
)
tt_packet_snapshot() {
    TT_PACKETS=$(iptables -t filter -n -v -x -L TTM4_FWD 2>/dev/null) || return 1
    printf '%s\n' "$TT_PACKETS" |
        awk '$3=="ACCEPT" && $7=="tt0" {tx+=$1} $3=="ACCEPT" && $6=="tt0" {rx+=$1} END {printf "{\"sent\":%.0f,\"received\":%.0f}\n",tx,rx}'
}
tt_verify_traffic() {
    tt_live || return 1
    tt_pid_matches && [ -f "$TT_ENABLED" ] && [ ! -f "$TT_PAUSED" ] || {
        TT_FAILURE_CODE=check_not_running; return 1;
    }
    TT_CHECK_START=$(cat "$TT_RUN/client.start")
    TT_CHECK_GUARD=false; tt_check_guard_rules && TT_CHECK_GUARD=true
    TT_CHECK_BEFORE=$(tt_packet_snapshot) || return 1
    sleep 10
    TT_CHECK_AFTER=$(tt_packet_snapshot) || return 1
    tt_check_guard_rules || TT_CHECK_GUARD=false
    tt_pid_matches && [ "$(cat "$TT_RUN/client.start")" = "$TT_CHECK_START" ] || return 1
    TT_CHECK_TIMER=$(tt_timer 300) || return 1
    [ ! -L "$TT_CONFIG/traffic-check.json" ] || return 1
    TT_CHECK_TMP=$(mktemp "$TT_CONFIG/.traffic-check.XXXXXX") || return 1
    jq -n --argjson before "$TT_CHECK_BEFORE" --argjson after "$TT_CHECK_AFTER" --argjson guard "$TT_CHECK_GUARD" \
        --arg generation "$TT_CHECK_START" --arg revision "$(tt_revision)" --argjson now "$(date +%s)" --argjson timer "$TT_CHECK_TIMER" \
        '{checked_at:$now,timer:$timer,generation:$generation,revision:$revision,rules_checked:$guard,leak_test_verified:false,
          sent_packets:($after.sent-$before.sent),received_packets:($after.received-$before.received),
          state:(if $guard|not then "incomplete" elif $after.sent<$before.sent or $after.received<$before.received then "counters_reset"
            elif $after.sent>$before.sent and $after.received>$before.received then "traffic_observed" else "idle" end)}' \
        >"$TT_CHECK_TMP" && chmod 600 "$TT_CHECK_TMP" && mv -f "$TT_CHECK_TMP" "$TT_CONFIG/traffic-check.json" && return 0
    rm -f "$TT_CHECK_TMP"
    return 1
}
tt_traffic_check_valid() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ "$(wc -c <"$1")" -le 4096 ] || return 1
    jq -e -s 'length==1 and (.[0] | type=="object" and
        (.checked_at|type=="number" and .>0 and floor==.) and
        (.generation|type=="string" and length>0) and (.revision|type=="string") and
        (.rules_checked|type=="boolean") and .leak_test_verified==false and
        (.sent_packets|type=="number" and floor==.) and (.received_packets|type=="number" and floor==.) and
        (.timer==null or (.timer|type=="object" and (.boot_id|type=="string" and length>0) and
            (.started|type=="number" and .>=0 and floor==.) and (.deadline|type=="number") and .deadline==(.started+300))) and
        (.state=="traffic_observed" or .state=="idle" or .state=="incomplete" or .state=="counters_reset"))' "$1" >/dev/null 2>&1
}
tt_preserve_traffic_check() {
    # Publication may migrate the old /tmp record once. Read-only status never
    # writes configuration; old observations are never promoted to fresh ones.
    [ ! -e "$TT_CONFIG/traffic-check.json" ] && [ ! -L "$TT_CONFIG/traffic-check.json" ] || return 0
    tt_traffic_check_valid "$TT_RUN/traffic-check.json" || return 0
    tt_atomic_json "$TT_RUN/traffic-check.json" "$TT_CONFIG/traffic-check.json"
}
tt_traffic_check_history() (
    report="$TT_CONFIG/traffic-check.json"
    [ -e "$report" ] || [ -L "$report" ] || report="$TT_RUN/traffic-check.json"
    tt_traffic_check_valid "$report" || { printf 'null\n'; return; }
    generation=; [ ! -f "$TT_RUN/client.start" ] || generation=$(cat "$TT_RUN/client.start")
    running=false
    if tt_pid_matches && [ -f "$TT_ENABLED" ] && [ ! -f "$TT_PAUSED" ]; then running=true; fi
    boot=$(tt_boot_id 2>/dev/null) || boot=
    remaining=$(tt_timer_remaining "$report") || remaining=0
    jq --arg generation "$generation" --arg revision "$(tt_revision)" --arg boot "$boot" \
        --argjson running "$running" --argjson remaining "$remaining" --argjson now "$(date +%s)" '
        (if .timer!=null and .timer.boot_id!=$boot then "router_restarted"
         elif $running|not then "client_stopped"
         elif .generation!=$generation then "client_restarted"
         elif .revision!=$revision then "settings_changed"
         elif .timer==null then (if .checked_at<=($now-300) then "expired" else "legacy" end)
         elif $remaining<=0 then "expired" else null end) as $reason |
        {checked_at,state,rules_checked,sent_packets,received_packets,leak_test_verified:false,
         fresh:($reason==null),stale_reason:$reason}' "$report"
)
tt_traffic_check_status() {
    # Compatibility contract: only a fresh observation may describe current
    # guards. Historical success is published separately, never as live proof.
    tt_traffic_check_history | jq 'if .fresh==true then del(.fresh,.stale_reason) else null end'
}

# Nonblocking snapshots: no sleep/probes and no recurring writes to flash.
# The caller holds control.lock. An observation is separate from manual checks.
tt_observe_traffic() (
    [ -z "$TT_ROOT" ] || return 0
    tt_pid_matches && [ -f "$TT_ENABLED" ] && [ ! -f "$TT_PAUSED" ] || return 0
    now=$(date +%s)
    current=$(tt_packet_snapshot) || return 1
    up=$(tt_uptime) && boot=$(tt_boot_id) || return 1
    generation=$(cat "$TT_RUN/client.start")
    revision=$(tt_revision)
    previous=null
    if [ -f "$TT_RUN/traffic-sample.json" ] && [ ! -L "$TT_RUN/traffic-sample.json" ] && [ "$(wc -c <"$TT_RUN/traffic-sample.json")" -le 4096 ]; then
        previous=$(jq -ce -s 'if length==1 and (.[0]|type=="object" and
            all(.sent,.received,.up,.at; type=="number" and .>=0 and floor==.) and
            all(.generation,.revision,.boot; type=="string")) then .[0] else error("sample") end' "$TT_RUN/traffic-sample.json" 2>/dev/null) || previous=null
    fi
    # Throttle the observation, not the baseline: firewall rebuilds reset counters.
    if [ -f "$TT_RUN/traffic-observation.json" ] && [ ! -L "$TT_RUN/traffic-observation.json" ]; then
        if jq -e --arg g "$generation" --arg r "$revision" --arg b "$boot" --argjson up "$up" --argjson now "$now" \
            '.generation==$g and .revision==$r and .boot==$b and .up<=$up and ($up-.up)<55 and (((($now-.checked_at)-($up-.up))|fabs)<=5)' \
            "$TT_RUN/traffic-observation.json" >/dev/null 2>&1; then return 0; fi
    fi
    rules=false; tt_check_guard_rules && rules=true
    sample=$(mktemp "$TT_RUN/.sample.XXXXXX") || return 1
    jq -n --argjson counters "$current" --arg g "$generation" --arg r "$revision" --arg b "$boot" --argjson up "$up" --argjson now "$now" \
        '$counters+{generation:$g,revision:$r,boot:$b,up:$up,at:$now}' >"$sample" || { rm -f "$sample"; return 1; }
    report=$(mktemp "$TT_RUN/.observation.XXXXXX") || { rm -f "$sample"; return 1; }
    if jq -n --argjson old "$previous" --slurpfile new "$sample" --argjson rules "$rules" --argjson now "$now" '
        $new[0] as $n | ($old!=null and $old.generation==$n.generation and $old.revision==$n.revision and $old.boot==$n.boot and $n.up>$old.up and ($n.up-$old.up)<=180 and (((($n.at-$old.at)-($n.up-$old.up))|fabs)<=5)) as $same |
        {checked_at:$now,generation:$n.generation,revision:$n.revision,boot:$n.boot,up:$n.up,rules_checked:$rules,leak_test_verified:false,
         interval_seconds:(if $same then $n.up-$old.up else 0 end),
         sent_packets:(if $same then $n.sent-$old.sent else 0 end),received_packets:(if $same then $n.received-$old.received else 0 end),
         state:(if $rules|not then "incomplete" elif $same|not then "sampling" elif $n.sent<$old.sent or $n.received<$old.received then "counters_reset" elif $n.sent>$old.sent and $n.received>$old.received then "traffic_observed" else "idle" end)}' >"$report"; then
        mv -f "$sample" "$TT_RUN/traffic-sample.json" && mv -f "$report" "$TT_RUN/traffic-observation.json"
    else rm -f "$sample" "$report"; return 1; fi
)
tt_observation_status() (
    [ -f "$TT_RUN/traffic-observation.json" ] && [ ! -L "$TT_RUN/traffic-observation.json" ] && [ "$(wc -c <"$TT_RUN/traffic-observation.json")" -le 4096 ] || { printf 'null\n'; return; }
    tt_pid_matches && [ -f "$TT_ENABLED" ] && [ ! -f "$TT_PAUSED" ] || { printf 'null\n'; return; }
    jq --arg g "$(cat "$TT_RUN/client.start")" --arg r "$(tt_revision)" --arg b "$(tt_boot_id)" --argjson up "$(tt_uptime)" --argjson now "$(date +%s)" '
        if .generation==$g and .revision==$r and .boot==$b and .up<=$up and ($up-.up)<=150 and (((($now-.checked_at)-($up-.up))|fabs)<=5) then
            {checked_at,state,interval_seconds,sent_packets,received_packets,rules_checked,leak_test_verified:false}
        else null end' "$TT_RUN/traffic-observation.json"
)

# Called after a successful rebuild, while locked: record new counter origins in
# RAM without changing the observation's date or replacing manual history.
tt_traffic_baseline() (
    [ -z "$TT_ROOT" ] || return 0
    tt_pid_matches && [ -f "$TT_ENABLED" ] && [ ! -f "$TT_PAUSED" ] || return 0
    counters=$(tt_packet_snapshot) || return 1
    file=$(mktemp "$TT_RUN/.baseline.XXXXXX") || return 1
    if jq -n --argjson c "$counters" --arg g "$(cat "$TT_RUN/client.start")" --arg r "$(tt_revision)" \
        --arg b "$(tt_boot_id)" --argjson up "$(tt_uptime)" --argjson at "$(date +%s)" \
        '$c+{generation:$g,revision:$r,boot:$b,up:$up,at:$at}' >"$file"; then
        mv -f "$file" "$TT_RUN/traffic-sample.json"
    else rm -f "$file"; return 1; fi
)
