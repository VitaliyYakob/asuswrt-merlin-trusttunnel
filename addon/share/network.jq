# Produces a declarative command plan. Never shell-evaluate its contents.
def cmd($a): {op:"command",argv:$a};
def remove($a): {op:"remove",argv:$a};
def jump($prog;$table;$parent;$chain): {op:"jump",program:$prog,table:$table,parent:$parent,chain:$chain};
def detach($prog;$table;$parent;$chain): {op:"detach",program:$prog,table:$table,parent:$parent,chain:$chain};
def restore($program;$lines): {op:"restore",program:$program,stdin:(($lines|join("\n"))+"\n")};
# Addon-only transit destination, NOT a resolver or an upstream TUN DNS address.
# v1.1.5 intercepts TCP/UDP port 53 in core/src/dns_handler.{h,cpp}; a nonempty
# endpoint.dns_upstreams is required before start, and resolves through the VPN.
# DNAT also moves queries addressed to the router out of the local routing table.
# 192.0.2.53 must never be assigned locally (checked during preflight).
"192.0.2.53" as $dns_transit |
(if .schema==1 then . + {networks:[{lan_if,sources}]} | del(.lan_if,.sources) else . end) as $p |
[$p.networks[] as $network | $network.sources[] | {source:.,interface:$network.lan_if}] as $rules |
if $action=="guard" then [
  restore("ip6tables-restore"; ["*filter",":TTM6_FWD - [0:0]",":TTM6_IN - [0:0]","-F TTM6_FWD","-F TTM6_IN"] +
    [$p.networks[] | "-A TTM6_FWD -i \(.lan_if) -j REJECT",
      "-A TTM6_IN -i \(.lan_if) -p udp --dport 53 -j REJECT",
      "-A TTM6_IN -i \(.lan_if) -p tcp --dport 53 -j REJECT"] + ["COMMIT"]),
  jump("ip6tables";"filter";"FORWARD";"TTM6_FWD"),
  jump("ip6tables";"filter";"INPUT";"TTM6_IN"),
  restore("iptables-restore"; ["*filter",":TTM4_FWD - [0:0]","-F TTM4_FWD"] +
    [$rules[] as $r | $p.local_access[]? |
      "-A TTM4_FWD -i \($r.interface) -s \($r.source) -d \(.destination) -o \(.lan_if) -j RETURN"] +
    [$rules[] | "-A TTM4_FWD -i \(.interface) -s \(.source) -o tt0 -j ACCEPT",
      "-A TTM4_FWD -i \(.interface) -s \(.source) -j REJECT",
      "-A TTM4_FWD -i tt0 -o \(.interface) -d \(.source) -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"] + ["COMMIT"]),
  jump("iptables";"filter";"FORWARD";"TTM4_FWD"),
  restore("iptables-restore"; ["*nat",":TTM4_DNS - [0:0]",":TTM4_SNAT - [0:0]","-F TTM4_DNS","-F TTM4_SNAT"] +
    [$rules[] | "-A TTM4_DNS -i \(.interface) -s \(.source) -p udp --dport 53 -j DNAT --to-destination \($dns_transit):53",
      "-A TTM4_DNS -i \(.interface) -s \(.source) -p tcp --dport 53 -j DNAT --to-destination \($dns_transit):53"] +
    [$rules|map(.source)|unique[] | "-A TTM4_SNAT -s \(.) -o tt0 -j MASQUERADE"] + ["COMMIT"]),
  jump("iptables";"nat";"PREROUTING";"TTM4_DNS"), jump("iptables";"nat";"POSTROUTING";"TTM4_SNAT"),
  cmd(["ip","-4","route","replace","prohibit","default","table",($p.table|tostring),"metric","32760"])
] + [$p.local_access[]? | cmd(["ip","-4","route","replace",.destination,"dev",.lan_if,"scope","link","table",($p.table|tostring),"metric","20"])] +
    [$rules|to_entries[] | {op:"rule",priority:($p.priority+.key),source:.value.source,interface:.value.interface,table:$p.table}]
elif $action=="up" then [cmd(["ip","-4","route","replace","default","dev","tt0","table",($p.table|tostring),"metric","10"])]
elif $action=="down" then [remove(["ip","-4","route","del","default","dev","tt0","table",($p.table|tostring),"metric","10"])]
elif $action=="disarm" then
  [$rules|to_entries[] | remove(["ip","-4","rule","del","pref",($p.priority+.key|tostring),"from",.value.source,"iif",.value.interface,"lookup",($p.table|tostring)])] +
  [$p.local_access[]? | remove(["ip","-4","route","del",.destination,"dev",.lan_if,"scope","link","table",($p.table|tostring),"metric","20"])] + [
  remove(["ip","-4","route","del","default","dev","tt0","table",($p.table|tostring),"metric","10"]),
  remove(["ip","-4","route","del","prohibit","default","table",($p.table|tostring),"metric","32760"]),
  detach("iptables";"nat";"PREROUTING";"TTM4_DNS"),detach("iptables";"nat";"POSTROUTING";"TTM4_SNAT"),
  detach("iptables";"filter";"FORWARD";"TTM4_FWD"),
  detach("ip6tables";"filter";"FORWARD";"TTM6_FWD"),detach("ip6tables";"filter";"INPUT";"TTM6_IN")]
else error("unknown network action") end
