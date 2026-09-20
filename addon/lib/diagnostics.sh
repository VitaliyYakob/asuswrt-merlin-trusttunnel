#!/bin/sh
# Read-only inventory. No packet probes or writes to router network configuration.
tt_client_inventory() {
    TT_LEASES="$TT_ROOT/var/lib/misc/dnsmasq.leases"
    [ -f "$TT_LEASES" ] || { printf '[]\n'; return 0; }
    head -n 1024 "$TT_LEASES" | jq -Rn '[inputs|split(" ")|map(select(length>0))|
        select(length>=4)|select(.[2]|test("^[0-9]+(\\.[0-9]+){3}$"))|
        select(.[2]|split(".")|all(.[];tonumber<=255))|
        {ip:.[2],name:(if .[3]=="*" then .[2] else .[3][0:128] end),
         mac:.[1],lease_expires:(.[0]|tonumber?)}]|unique_by(.ip)'
}
tt_guard_state() {
    [ -z "$TT_ROOT" ] || { printf 'unverified\n'; return 0; }
    [ -f "$TT_ENABLED" ] || { printf 'disabled\n'; return 0; }
    if iptables -t filter -C FORWARD -j TTM4_FWD >/dev/null 2>&1 &&
        ip6tables -t filter -C FORWARD -j TTM6_FWD >/dev/null 2>&1 &&
        ip6tables -t filter -C INPUT -j TTM6_IN >/dev/null 2>&1 &&
        ip -4 route show table 871 | grep -q 'prohibit default'; then printf 'installed_unverified\n'
    else printf 'incomplete\n'; fi
}
tt_diagnostics() {
    TT_DIAG_RETRY=null
    [ ! -f "$TT_RUN/retry.json" ] || TT_DIAG_RETRY=$(jq '{failures,next_attempt}' "$TT_RUN/retry.json")
    TT_DIAG_TOOLS=
    for TT_DIAG_TOOL in jq ip iptables ip6tables iptables-restore ip6tables-restore flock openssl sha256sum; do
        TT_DIAG_OK=false; type "$TT_DIAG_TOOL" >/dev/null 2>&1 && TT_DIAG_OK=true
        TT_DIAG_TOOLS="$TT_DIAG_TOOLS
$(jq -nc --arg name "$TT_DIAG_TOOL" --argjson available "$TT_DIAG_OK" '{name:$name,available:$available}')"
    done
    TT_DIAG_ARCH=offline; TT_DIAG_MODEL=unknown; TT_DIAG_FW=unknown; TT_DIAG_ACCEL=unknown
    TT_DIAG_EARLIER=null; TT_DIAG_BINARY=false; TT_DIAG_HASH=
    [ ! -x "$TT_BIN" ] || TT_DIAG_BINARY=true
    if [ -f "$TT_BIN.sha256" ]; then
        TT_DIAG_HASH=$(head -n 1 "$TT_BIN.sha256")
        printf '%s' "$TT_DIAG_HASH" | grep -Eq '^[0-9a-f]{64}$' || TT_DIAG_HASH=
    fi
    if [ -z "$TT_ROOT" ]; then
        TT_DIAG_ARCH=$(uname -m)
        TT_DIAG_RULES=$(ip -4 rule show 2>/dev/null) &&
            TT_DIAG_EARLIER=$(printf '%s\n' "$TT_DIAG_RULES" | awk -F: '$1>0 && $1<17100 {n++} END {print n+0}')
        if type nvram >/dev/null 2>&1; then
            TT_DIAG_MODEL=$(nvram get productid)
            TT_DIAG_FW="$(nvram get firmver).$(nvram get buildno)_$(nvram get extendno)"
            TT_DIAG_ACCEL=$(nvram get ctf_disable)
        fi
    fi
    printf '%s\n' "$TT_DIAG_TOOLS" | jq -s --arg model "$TT_DIAG_MODEL" --arg arch "$TT_DIAG_ARCH" \
        --arg firmware "$TT_DIAG_FW" --arg acceleration "$TT_DIAG_ACCEL" --arg guard "$(tt_guard_state)" \
        --arg version "$TT_VERSION" --arg revision "$(tt_revision)" --argjson retry "$TT_DIAG_RETRY" \
        --argjson earlier_rules "$TT_DIAG_EARLIER" --argjson binary_present "$TT_DIAG_BINARY" --arg hash "$TT_DIAG_HASH" \
        '{schema:1,addon_version:$version,revision:$revision,model:$model,architecture:$arch,
          firmware:$firmware,tools:.,guard:$guard,ctf_disable:$acceleration,
          hnd_acceleration_verified:false,packet_path_verified:false,
          browser_transport_hardware_verified:false,client_version_target:"1.1.5",retry:$retry,
          earlier_ipv4_rules:$earlier_rules,client_binary_present:$binary_present,recorded_binary_sha256:$hash}'
}
