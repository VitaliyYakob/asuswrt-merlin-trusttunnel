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
    TT_CHECK_TMP=$(mktemp "$TT_RUN/.traffic-check.XXXXXX") || return 1
    jq -n --argjson before "$TT_CHECK_BEFORE" --argjson after "$TT_CHECK_AFTER" --argjson guard "$TT_CHECK_GUARD" \
        --arg generation "$TT_CHECK_START" --arg revision "$(tt_revision)" --argjson now "$(date +%s)" \
        '{checked_at:$now,generation:$generation,revision:$revision,rules_checked:$guard,leak_test_verified:false,
          sent_packets:($after.sent-$before.sent),received_packets:($after.received-$before.received),
          state:(if $guard|not then "incomplete" elif $after.sent<$before.sent or $after.received<$before.received then "counters_reset"
            elif $after.sent>$before.sent and $after.received>$before.received then "traffic_observed" else "idle" end)}' \
        >"$TT_CHECK_TMP" && mv -f "$TT_CHECK_TMP" "$TT_RUN/traffic-check.json"
}
tt_traffic_check_status() {
    [ -f "$TT_RUN/traffic-check.json" ] && [ -f "$TT_RUN/client.start" ] || { printf 'null\n'; return; }
    jq --arg generation "$(cat "$TT_RUN/client.start")" --arg revision "$(tt_revision)" --argjson now "$(date +%s)" \
        'if .generation==$generation and .revision==$revision and .checked_at<=$now and .checked_at>($now-300) then . else null end' "$TT_RUN/traffic-check.json"
}
