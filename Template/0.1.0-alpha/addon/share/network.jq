# Produces a declarative command plan. Never shell-evaluate its contents.
def cmd($a): {op:"command",argv:$a};
def remove($a): {op:"remove",argv:$a};
def jump($prog;$table;$parent;$chain): {op:"jump",program:$prog,table:$table,parent:$parent,chain:$chain};
def detach($prog;$table;$parent;$chain): {op:"detach",program:$prog,table:$table,parent:$parent,chain:$chain};
def restore($program;$lines): {op:"restore",program:$program,stdin:(($lines|join("\n"))+"\n")};
. as $p |
if $action=="guard" then [
  restore("ip6tables-restore"; ["*filter",":TTM6_FWD - [0:0]",":TTM6_IN - [0:0]","-F TTM6_FWD","-F TTM6_IN",
    "-A TTM6_FWD -i \($p.lan_if) -j REJECT",
    "-A TTM6_IN -i \($p.lan_if) -p udp --dport 53 -j REJECT",
    "-A TTM6_IN -i \($p.lan_if) -p tcp --dport 53 -j REJECT","COMMIT"]),
  jump("ip6tables";"filter";"FORWARD";"TTM6_FWD"),
  jump("ip6tables";"filter";"INPUT";"TTM6_IN"),
  restore("iptables-restore"; ["*filter",":TTM4_FWD - [0:0]","-F TTM4_FWD"] +
    [$p.sources[] | "-A TTM4_FWD -i \($p.lan_if) -s \(.) -o tt0 -j ACCEPT",
      "-A TTM4_FWD -i \($p.lan_if) -s \(.) -j REJECT",
      "-A TTM4_FWD -i tt0 -o \($p.lan_if) -d \(.) -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"] + ["COMMIT"]),
  jump("iptables";"filter";"FORWARD";"TTM4_FWD"),
  restore("iptables-restore"; ["*nat",":TTM4_DNS - [0:0]",":TTM4_SNAT - [0:0]","-F TTM4_DNS","-F TTM4_SNAT"] +
    [$p.sources[] | "-A TTM4_DNS -i \($p.lan_if) -s \(.) -p udp --dport 53 -j DNAT --to-destination \($p.dns_ipv4):53",
      "-A TTM4_DNS -i \($p.lan_if) -s \(.) -p tcp --dport 53 -j DNAT --to-destination \($p.dns_ipv4):53",
      "-A TTM4_SNAT -s \(.) -o tt0 -j MASQUERADE"] + ["COMMIT"]),
  jump("iptables";"nat";"PREROUTING";"TTM4_DNS"), jump("iptables";"nat";"POSTROUTING";"TTM4_SNAT"),
  cmd(["ip","-4","route","replace","prohibit","default","table",($p.table|tostring),"metric","32760"])
] + [$p.sources|to_entries[] | {op:"rule",priority:($p.priority+.key),source:.value,interface:$p.lan_if,table:$p.table}]
elif $action=="up" then [cmd(["ip","-4","route","replace","default","dev","tt0","table",($p.table|tostring),"metric","10"])]
elif $action=="down" then [remove(["ip","-4","route","del","default","dev","tt0","table",($p.table|tostring),"metric","10"])]
elif $action=="disarm" then
  [$p.sources|to_entries[] | remove(["ip","-4","rule","del","pref",($p.priority+.key|tostring),"from",.value,"iif",$p.lan_if,"lookup",($p.table|tostring)])] + [
  remove(["ip","-4","route","del","default","dev","tt0","table",($p.table|tostring),"metric","10"]),
  remove(["ip","-4","route","del","prohibit","default","table",($p.table|tostring),"metric","32760"]),
  detach("iptables";"nat";"PREROUTING";"TTM4_DNS"),detach("iptables";"nat";"POSTROUTING";"TTM4_SNAT"),
  detach("iptables";"filter";"FORWARD";"TTM4_FWD"),
  detach("ip6tables";"filter";"FORWARD";"TTM6_FWD"),detach("ip6tables";"filter";"INPUT";"TTM6_IN")]
else error("unknown network action") end
