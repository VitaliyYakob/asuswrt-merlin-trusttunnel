#!/bin/sh
# Read actual HND state; the legacy ctf_disable flag is not authoritative on AX86U.
tt_acceleration_state() (
    [ -z "$TT_ROOT" ] || { printf 'unknown\n'; return; }
    if type fc >/dev/null 2>&1; then
        TT_ACCEL_STATUS=$(fc status 2>/dev/null) || { printf 'unknown\n'; return; }
        if printf '%s\n' "$TT_ACCEL_STATUS" | grep -Eq 'HW Acceleration[[:space:]]*<Enabled>|Flow (Ucast |Mcast )?Learning Enabled'; then
            printf 'enabled\n'
        elif printf '%s\n' "$TT_ACCEL_STATUS" | grep -Eq 'HW Acceleration[[:space:]]*<Disabled>' &&
            printf '%s\n' "$TT_ACCEL_STATUS" | grep -Eq 'Flow (Ucast )?Learning Disabled'; then
            printf 'disabled\n'
        else printf 'unknown\n'; fi
    elif type nvram >/dev/null 2>&1; then
        case "$(tt_nvram_get ctf_disable)" in 1) printf 'disabled\n';; 0) printf 'enabled\n';; *) printf 'unknown\n';; esac
    else printf 'unknown\n'; fi
)
tt_selective_offload_supported() {
    [ -z "$TT_ROOT" ] || return 1
    type fc >/dev/null 2>&1 &&
        grep -qx SKIPLOG "$TT_PROC/net/ip_tables_targets" &&
        grep -qx SKIPLOG "$TT_PROC/net/ip6_tables_targets"
}
tt_start_failure() { TT_FAILURE_CODE=$1; tt_error "$2"; return 1; }
tt_tun_available() { [ -c "$TT_ROOT/dev/net/tun" ]; }
tt_ensure_tun() {
    [ -z "$TT_ROOT" ] || { tt_start_failure tun_unavailable 'TUN loading is prohibited with TT_ROOT'; return 1; }
    tt_tun_available && return 0
    # Load only the firmware's module, never download a module or fabricate a device.
    if type modprobe >/dev/null 2>&1; then modprobe tun >/dev/null 2>&1 || :; fi
    tt_tun_available || { tt_start_failure tun_unavailable 'firmware TUN module could not create /dev/net/tun'; return 1; }
}
tt_start_readiness() (
    TT_READY_ENDPOINT=false; TT_READY_POLICY=false; TT_READY_TUN=false
    tt_validate endpoint "$TT_ENDPOINT" >/dev/null 2>&1 && TT_READY_ENDPOINT=true
    tt_validate policy "$TT_POLICY" >/dev/null 2>&1 && TT_READY_POLICY=true
    tt_tun_available && TT_READY_TUN=true
    TT_READY_OFFLOAD=false; tt_selective_offload_supported && TT_READY_OFFLOAD=true
    jq -n --argjson selective_offload "$TT_READY_OFFLOAD" --argjson endpoint "$TT_READY_ENDPOINT" --argjson policy "$TT_READY_POLICY" \
        --argjson tun "$TT_READY_TUN" --arg acceleration "$(tt_acceleration_state)" \
        '{endpoint_valid:$endpoint,policy_valid:$policy,tun_available:$tun,acceleration:$acceleration,selective_offload:$selective_offload,
          blockers:([if $endpoint then empty else "endpoint_missing" end,
            if $policy then empty else "policy_missing" end,
            if $selective_offload then empty else "offload_unavailable" end]),
          notes:([if $tun then empty else "tun_load_on_start" end])}'
)
