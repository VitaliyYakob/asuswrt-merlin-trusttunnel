#!/bin/sh
# Broadcom Merlin: wlN_ifname names the radio's OS interface; wlN_vifnames
# lists wlN.M guest interfaces. Never infer a wireless unit from a br number.
# Sources: RMerl/asuswrt-merlin.ng release/src/router/rc/init.c (wl_defaults)
# and release/src/router/shared/defaults.c (wl_ifname, wl_vifnames, wl_ssid).
tt_wireless_ifnames() (
    [ -z "$TT_ROOT" ] || { printf '[]\n'; return 0; }
    type nvram >/dev/null 2>&1 || { printf '[]\n'; return 0; }
    set -f
    TT_WIFI_MAP=
    # The intended AX86U has two radios. Also cover up to four Broadcom radios
    # without dumping NVRAM or relying on wl_ifnames ordering.
    for TT_WIFI_UNIT in 0 1 2 3; do
        TT_WIFI_PREFIX="wl$TT_WIFI_UNIT"
        TT_WIFI_OS=$(nvram get "${TT_WIFI_PREFIX}_ifname" 2>/dev/null) || TT_WIFI_OS=
        if printf '%s' "$TT_WIFI_OS" | grep -Eq '^[a-zA-Z0-9_.:-]{1,15}$'; then
            TT_WIFI_MAP="$TT_WIFI_MAP
$(jq -nc --arg ifname "$TT_WIFI_OS" --arg nvif "$TT_WIFI_PREFIX" '{ifname:$ifname,nvif:$nvif}')"
        fi
        TT_WIFI_VIFS=$(nvram get "${TT_WIFI_PREFIX}_vifnames" 2>/dev/null) || TT_WIFI_VIFS=
        for TT_WIFI_VIF in $TT_WIFI_VIFS; do
            printf '%s' "$TT_WIFI_VIF" | grep -Eq "^wl${TT_WIFI_UNIT}\\.[0-9]+$" || continue
            TT_WIFI_OS=$(nvram get "${TT_WIFI_VIF}_ifname" 2>/dev/null) || TT_WIFI_OS=
            [ -n "$TT_WIFI_OS" ] || TT_WIFI_OS=$TT_WIFI_VIF
            printf '%s' "$TT_WIFI_OS" | grep -Eq '^[a-zA-Z0-9_.:-]{1,15}$' || continue
            TT_WIFI_MAP="$TT_WIFI_MAP
$(jq -nc --arg ifname "$TT_WIFI_OS" --arg nvif "$TT_WIFI_VIF" '{ifname:$ifname,nvif:$nvif}')"
        done
    done
    printf '%s\n' "$TT_WIFI_MAP" | jq -s 'unique'
)
tt_bridge_ssids() (
    [ -z "$TT_ROOT" ] || { printf '[]\n'; return 0; }
    type nvram >/dev/null 2>&1 || { printf '[]\n'; return 0; }
    TT_BRIDGE_SSIDS=
    for TT_MEMBER_PATH in "$1"/brif/*; do
        [ -e "$TT_MEMBER_PATH" ] || continue
        TT_MEMBER=${TT_MEMBER_PATH##*/}
        TT_MEMBER_NVIFS=$(printf '%s\n' "$2" | jq -r --arg member "$TT_MEMBER" \
            '[.[]|select(.ifname==$member)|.nvif]|unique|
                if length==1 then .[0] elif length>1 then "ambiguous" else empty end') || return 1
        [ "$TT_MEMBER_NVIFS" != ambiguous ] || continue
        if [ -z "$TT_MEMBER_NVIFS" ]; then
            # An actual wlN.M member carries its NVRAM identity even when the
            # optional vifnames list is empty. Respect a conflicting OS alias.
            printf '%s' "$TT_MEMBER" | grep -Eq '^wl[0-3](\.[0-9]+)?$' || continue
            TT_MEMBER_ALIAS=$(nvram get "${TT_MEMBER}_ifname" 2>/dev/null) || TT_MEMBER_ALIAS=
            [ -z "$TT_MEMBER_ALIAS" ] || [ "$TT_MEMBER_ALIAS" = "$TT_MEMBER" ] || continue
            TT_MEMBER_NVIFS=$TT_MEMBER
        fi
        # jq reads raw SSID bytes through stdin; quotes, Unicode and newlines
        [ "$(nvram get "${TT_MEMBER_NVIFS}_bss_enabled" 2>/dev/null)" != 0 ] || continue
        # remain data. Remove only the newline added by nvram get.
        # The sentinel preserves trailing newlines across shell substitution.
        TT_MEMBER_SSID_RAW=$(nvram get "${TT_MEMBER_NVIFS}_ssid" 2>/dev/null && printf '.') || continue
        TT_MEMBER_SSID=$(printf '%s' "${TT_MEMBER_SSID_RAW%.}" |
            jq -Rs --arg nvif "$TT_MEMBER_NVIFS" '{ssid:sub("\n$";""),primary:($nvif|test("^wl[0-3]$"))}|select(.ssid|length>0)') || return 1
        TT_BRIDGE_SSIDS="$TT_BRIDGE_SSIDS
$TT_MEMBER_SSID"
    done
    # Prefer the main radio name over virtual/service SSIDs; deduplicate stably.
    printf '%s\n' "$TT_BRIDGE_SSIDS" | jq -s 'sort_by(.primary|not)|map(.ssid)|reduce .[] as $s ([]; if index($s)==null then .+[$s] else . end)'
)
tt_discover_networks() {
    # Offline sandboxes must never inspect the development host's networking.
    if [ -n "$TT_ROOT" ]; then printf '[]\n'; return 0; fi
    TT_DISCOVERY_RESULT=
    TT_DISCOVERY_WIFI=$(tt_wireless_ifnames) || return 1
    for TT_BRIDGE_PATH in "$TT_SYS"/class/net/br*/bridge; do
        [ -d "$TT_BRIDGE_PATH" ] || continue
        TT_BRIDGE_PARENT=${TT_BRIDGE_PATH%/bridge}
        TT_BRIDGE_NAME=${TT_BRIDGE_PARENT##*/}
        printf '%s' "$TT_BRIDGE_NAME" | grep -Eq '^br[0-9]+(\.[0-9]+)?$' || continue
        TT_DISCOVERY_ADDRESSES=$(ip -4 -o addr show dev "$TT_BRIDGE_NAME" 2>/dev/null) || return 1
        TT_DISCOVERY_SSIDS=$(tt_bridge_ssids "$TT_BRIDGE_PARENT" "$TT_DISCOVERY_WIFI") || return 1
        TT_DISCOVERY_ITEM=$(printf '%s\n' "$TT_DISCOVERY_ADDRESSES" | awk '$3=="inet" {print $4}' |
            jq -Rn --arg interface "$TT_BRIDGE_NAME" -f "$TT_BASE/share/inventory.jq" |
            jq --argjson ssids "$TT_DISCOVERY_SSIDS" '. + {ssids:$ssids,
                display_name:(if ($ssids|length)>0 then $ssids[0] else "Локальная сеть (SSID не определён)" end)}') || return 1
        # SSID renaming does not change identity; bridge members/subnets do.
        TT_ID_MEMBERS=$(for TT_ID_PATH in "$TT_BRIDGE_PARENT"/brif/*; do
            [ ! -e "$TT_ID_PATH" ] || printf '%s\n' "${TT_ID_PATH##*/}"
        done | LC_ALL=C sort)
        TT_ID_HASH=$(printf '%s\n%s\n' "$TT_ID_MEMBERS" "$(printf '%s' "$TT_DISCOVERY_ITEM" | jq -c .sources)" | sha256sum | awk '{print $1}') || return 1
        TT_DISCOVERY_ITEM=$(printf '%s' "$TT_DISCOVERY_ITEM" | jq --arg identity "$TT_ID_HASH" '. + {identity:$identity}') || return 1
        TT_DISCOVERY_RESULT="$TT_DISCOVERY_RESULT
$TT_DISCOVERY_ITEM"
    done
    printf '%s\n' "$TT_DISCOVERY_RESULT" | jq -s .
}
