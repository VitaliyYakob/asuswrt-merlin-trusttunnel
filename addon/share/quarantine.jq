# Independently validated old/new policies. Quarantine covers their union.
def nets: if .schema==1 then [{lan_if,sources}] else .networks end;
def restore($program;$lines): {op:"restore",program:$program,stdin:(($lines|join("\n"))+"\n")};
def hook($operation;$program;$parent;$chain): {op:$operation,program:$program,table:"filter",parent:$parent,chain:$chain};
.[0] as $old | .[1] as $new |
[$old,$new|nets[] as $n|$n.sources[]|{lan_if:$n.lan_if,source:.}]|unique as $union |
if $mode=="remove" then [
    hook("detach";"iptables";"FORWARD";"TTM4_TXN"),hook("detach";"iptables";"INPUT";"TTM4_TXNI"),
    hook("detach";"ip6tables";"FORWARD";"TTM6_TXN"),hook("detach";"ip6tables";"INPUT";"TTM6_TXNI")]
else [
    restore("iptables-restore";["*filter",":TTM4_TXN - [0:0]",":TTM4_TXNI - [0:0]","-F TTM4_TXN","-F TTM4_TXNI"]+
        (if $mode=="trial" then [$new|nets[] as $n|$n.sources[]|"-A TTM4_TXN -i \($n.lan_if) -s \(.) -j RETURN"] else [] end)+
        [$union[]|"-A TTM4_TXN -i \(.lan_if) -s \(.source) -j REJECT",
          "-A TTM4_TXNI -i \(.lan_if) -s \(.source) -p udp --dport 53 -j REJECT",
          "-A TTM4_TXNI -i \(.lan_if) -s \(.source) -p tcp --dport 53 -j REJECT"]+["COMMIT"]),
    hook("jump";"iptables";"FORWARD";"TTM4_TXN"),hook("jump";"iptables";"INPUT";"TTM4_TXNI"),
    restore("ip6tables-restore";["*filter",":TTM6_TXN - [0:0]",":TTM6_TXNI - [0:0]","-F TTM6_TXN","-F TTM6_TXNI"]+
        [$union|map(.lan_if)|unique[]|"-A TTM6_TXN -i \(.) -j REJECT",
          "-A TTM6_TXNI -i \(.) -p udp --dport 53 -j REJECT",
          "-A TTM6_TXNI -i \(.) -p tcp --dport 53 -j REJECT"]+["COMMIT"]),
    hook("jump";"ip6tables";"FORWARD";"TTM6_TXN"),hook("jump";"ip6tables";"INPUT";"TTM6_TXNI")]
end
