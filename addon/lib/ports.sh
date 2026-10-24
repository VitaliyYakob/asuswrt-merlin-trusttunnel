#!/bin/sh
# Model mapping, not a selected-port default. Source: r80xcore/mervlan.
# Only untagged Ethernet ingress on native AX86U br0 is supported initially.
tt_port_inventory() (
    [ -z "$TT_ROOT" ] || { printf '[]\n'; return; }
    model=$(tt_nvram_get productid) || return 1
    [ "$model" = RT-AX86U ] || { printf '[]\n'; return; }
    dual=$(tt_nvram_get wans_dualwan) && stb=$(tt_nvram_get switch_stb_x) && lag=$(tt_nvram_get lacp_enabled) || return 1
    wan0=$(tt_nvram_get wan0_ifname) && wan1=$(tt_nvram_get wan1_ifname) || return 1
    networks=${TT_DISCOVERED_NETWORKS:-}
    [ -n "$networks" ] || networks=$(tt_discover_networks) || return 1
    identity=$(printf '%s' "$networks" | jq -r '.[]|select(.lan_if=="br0")|.identity')
    output=
    for item in LAN1:eth4 LAN2:eth3 LAN3:eth2 LAN4:eth1 2.5G:eth5; do
        interface=${item#*:}; label=${item%:*}; reason=
        [ -d "$TT_SYS/class/net/br0/brif/$interface" ] || reason='Порт не принадлежит основной локальной сети'
        case "$dual" in 'wan none'|'wan2 none') :;; *) reason='Выбор портов недоступен при Dual WAN';; esac
        case "$stb:$lag" in 0:0|0:) :;; *) reason='Выбор портов недоступен при IPTV или агрегации LAN';; esac
        if [ "$interface" = "$wan0" ] || [ "$interface" = "$wan1" ]; then reason='Порт используется для WAN'; fi
        [ -n "$identity" ] || reason='Не получена привязка к локальной сети'
        type ebtables >/dev/null 2>&1 || reason='В прошивке отсутствует ebtables'
        carrier=false; [ "$(cat "$TT_SYS/class/net/$interface/carrier" 2>/dev/null)" != 1 ] || carrier=true
        output="$output
$(jq -nc --arg interface "$interface" --arg label "$label" --arg identity "$identity" --arg reason "$reason" --argjson carrier "$carrier" \
    '{interface:$interface,label:$label,lan_if:"br0",identity:$identity,available:($reason==""),reason:$reason,link_up:$carrier}')"
    done
    printf '%s\n' "$output" | jq -s .
)
tt_ports_selected() { jq -e '((.ports//[])|length)>0' "$1" >/dev/null; }
tt_ports_check() (
    tt_ports_selected "$TT_POLICY" || return 0
    tt_live || return 1
    inventory=$(tt_port_inventory) || return 1
    jq -e --argjson inventory "$inventory" 'all(.ports[]; . as $p | any($inventory[]; .available and .interface==$p.interface and .lan_if==$p.lan_if and .identity==$p.identity))' "$TT_POLICY" >/dev/null || {
        tt_error 'selected LAN ports are unavailable or their topology changed'; return 1;
    }
    type ebtables >/dev/null 2>&1 || return 1
    if [ ! -f "$TT_RUN/ports-owned" ]; then
        if ebtables -t broute -L TTM_PORTS >/dev/null 2>&1 || iptables -t mangle -S TTM4_PORT >/dev/null 2>&1 || ip -4 rule show | grep -q '^17132:'; then
            tt_error 'LAN port namespace is occupied'; return 1
        fi
    fi
    # Reserve two mark bits conservatively. Never adopt or rewrite another VPN's marks.
    foreign=$(iptables-save -t mangle 2>/dev/null) || return 1
    if printf '%s\n' "$foreign" | grep '^-A ' | grep -v '^-A TTM4_PORT ' | grep -Eq -- '-j (MARK|CONNMARK)( |$)'; then
        tt_error 'LAN port marking conflicts with another mangle policy'; return 1
    fi
    if ip -4 rule show | grep -v '^17132:' | grep -q fwmark; then
        tt_error 'LAN port marking conflicts with another marked routing policy'; return 1
    fi
    for table in broute nat filter; do
        rules=$(ebtables -t "$table" -L --Lx 2>/dev/null) || return 1
        if printf '%s\n' "$rules" | grep -v -- '-A TTM_PORTS ' | grep -q -- '-j mark '; then
            tt_error 'LAN port marking conflicts with another Ethernet marking policy'; return 1
        fi
    done
)
tt_ports_claim() {
    [ ! -f "$TT_RUN/ports-owned" ] || return 0
    tt_live || return 1
    if ebtables -t broute -L TTM_PORTS >/dev/null 2>&1; then tt_error 'Ethernet port namespace is occupied'; return 1; fi
    : >"$TT_RUN/ports-owned"
}
tt_port_rule() {
    # Exact tuple only; a foreign rule at this priority is never deleted.
    ip -4 rule del pref 17132 fwmark 0x10000000/0x10000000 iif br0 lookup 871 2>/dev/null || :
    if ip -4 rule show | grep -q '^17132:'; then tt_error 'LAN port routing priority conflict'; return 1; fi
    [ "$1" != add ] || ip -4 rule add pref 17132 fwmark 0x10000000/0x10000000 iif br0 lookup 871
}
tt_ports_classifier() (
    # $1 is a locally generated array of {interface,mark}. The global lock is held.
    tt_live || return 1
    printf '%s' "$1" | jq -e 'type=="array" and length<=5 and all(.[]; type=="object" and
      (.interface|type=="string" and test("^eth[1-5]$")) and (.mark=="0x10000000" or .mark=="0x20000000")) and (unique_by(.interface)|length)==length' >/dev/null || return 1
    [ -f "$TT_RUN/ports-owned" ] || return 1
    entries=$1
    file=$(mktemp "$TT_RUN/.ethernet.XXXXXX") || return 1
    trap 'rm -f "$file"' EXIT
    # Work on an atomic table snapshot: never flush the live shared table.
    ebtables -t broute --atomic-file "$file" --atomic-save || return 1
    original=$(ebtables -t broute --atomic-file "$file" -L) || return 1
    if ebtables -t broute --atomic-file "$file" -L TTM_PORTS >/dev/null 2>&1; then
        ebtables -t broute --atomic-file "$file" -F TTM_PORTS || return 1
        # Legacy ebtables prints a bare chain jump without a trailing space.
        # Remove every exact owned hook from the snapshot, including duplicates
        # left by older refreshes. Never delete selector-bearing foreign hooks.
        removed=0
        while ebtables -t broute --atomic-file "$file" -L BROUTING --Lx | grep -Eq -- ' -A BROUTING -j TTM_PORTS([[:space:]]|$)'; do
            [ "$removed" -lt 64 ] || return 1
            ebtables -t broute --atomic-file "$file" -D BROUTING -j TTM_PORTS || return 1
            removed=$((removed+1))
        done
    else ebtables -t broute --atomic-file "$file" -N TTM_PORTS || return 1; fi
    lines=$(printf '%s' "$entries" | jq -r '.[]|"\(.interface) \(.mark)"') || return 1
    while read -r interface mark; do
        [ -n "$interface" ] || continue
        case "$interface:$mark" in eth[1-5]:0x10000000|eth[1-5]:0x20000000) :;; *) return 1;; esac
        # OR leaves all unreserved firmware bits intact. Replies are never restored to skb mark.
        ebtables -t broute --atomic-file "$file" -A TTM_PORTS -i "$interface" -j mark --mark-or "$mark" --mark-target CONTINUE || return 1
    done <<EOF
$lines
EOF
    if [ -n "$lines" ]; then
        # User chains default to ACCEPT on legacy ebtables. Return explicitly
        # so firmware guest-isolation rules later in BROUTING still execute.
        ebtables -t broute --atomic-file "$file" -A TTM_PORTS -j RETURN || return 1
        ebtables -t broute --atomic-file "$file" -I BROUTING 1 -j TTM_PORTS || return 1
    else ebtables -t broute --atomic-file "$file" -X TTM_PORTS || return 1; fi
    # Do not overwrite a table that firmware/another addon changed meanwhile.
    live=$(ebtables -t broute -L) || return 1
    [ "$live" = "$original" ] || { tt_error 'Ethernet rules changed concurrently; retry after firewall settles'; return 1; }
    ebtables -t broute --atomic-file "$file" --atomic-commit || return 1
    listing=$(ebtables -t broute -L --Lx) || return 1
    printf '%s\n' "$listing" | sha256sum | awk '{print $1}' >"$TT_RUN/ports-rules.sha256" || return 1
    # Clear learned acceleration only on selected Ethernet interfaces, not all router flows.
    interfaces=$(printf '%s' "$entries" | jq -r '.[].interface' | LC_ALL=C sort -u)
    for interface in $interfaces; do env fc flush --if "$interface" >/dev/null 2>&1 || return 1; done
    printf '%s\n' "$entries" >"$TT_RUN/ports-active.json"
)
tt_ports_guard() {
    [ -f "$TT_RUNTIME_POLICY" ] && tt_ports_selected "$TT_RUNTIME_POLICY" || return 0
    tt_ports_check && tt_ports_claim || return 1
    [ ! -e "$TT_CONFIG/transaction/manifest.json" ] || return 0
    TT_PORT_ENTRIES=$(jq '[.ports[]|{interface,mark:"0x10000000"}]' "$TT_RUNTIME_POLICY") || return 1
    tt_ports_classifier "$TT_PORT_ENTRIES"
}
tt_ports_transaction() {
    TT_PORT_UNION=$(jq -s --arg mode "$1" --slurpfile current "$TT_POLICY" '
        .[0] as $old | .[1] as $new |
        if $mode=="remove" then [$current[0].ports[]?|{interface,mark:"0x10000000"}]
        else [($old.ports//[])+($new.ports//[])|unique_by(.interface)[]|. as $p |
          {interface,mark:(if $mode=="trial" and any($new.ports[]?;.interface==$p.interface) then "0x10000000" else "0x20000000" end)}] end' \
        "$TT_CONFIG/transaction/old-policy.json" "$TT_CONFIG/transaction/new-policy.json") || return 1
    if [ "$TT_PORT_UNION" = '[]' ] && [ ! -f "$TT_RUN/ports-owned" ]; then return 0; fi
    tt_ports_claim && tt_ports_classifier "$TT_PORT_UNION"
}
tt_ports_remove() {
    [ -f "$TT_RUN/ports-owned" ] || return 0
    tt_ports_classifier '[]' || return 1
    rm -f "$TT_RUN/ports-owned" "$TT_RUN/ports-active.json" "$TT_RUN/ports-rules.sha256"
}
tt_ports_integrity() (
    [ -f "$TT_RUN/ports-owned" ] && [ -f "$TT_RUN/ports-active.json" ] || return 1
    expected=$(jq -c '[.ports[]|{interface,mark:"0x10000000"}]|sort_by(.interface)' "$TT_RUNTIME_POLICY") || return 1
    actual=$(jq -c 'sort_by(.interface)' "$TT_RUN/ports-active.json") || return 1
    [ "$expected" = "$actual" ] || return 1
    # Read-only comparison with the exact listing saved after atomic activation.
    [ -f "$TT_RUN/ports-rules.sha256" ] || return 1
    listing=$(ebtables -t broute -L --Lx) || return 1
    actual=$(printf '%s\n' "$listing" | sha256sum | awk '{print $1}') || return 1
    [ "$actual" = "$(cat "$TT_RUN/ports-rules.sha256")" ] || return 1
    ip -4 rule show | grep -Eq '^17132:.*fwmark 0x10000000/0x10000000 iif br0 lookup 871( |$)'
)
