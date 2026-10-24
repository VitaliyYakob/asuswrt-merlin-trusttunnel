# Validation is shared by the router and host-side regression tests.
def require($condition; $message): if $condition then . else error($message) end;
def text($max): type == "string" and length > 0 and length <= $max and (test("[\\x00-\\x1f\\x7f]")|not);
def ipv4:
  if type != "string" then false else
    split(".") as $p | ($p|length)==4 and
    all($p[]; test("^(0|[1-9][0-9]{0,2})$") and (tonumber <= 255))
  end;
def private_cidr:
  if type != "string" or (test("^[0-9.]+/[0-9]{1,2}$")|not) then false else
    split("/") as $p | ($p[1]|tonumber) as $n |
    ($p[0]|split(".")|map(tonumber)) as $o |
    ($p[0]|ipv4) and $n >= 8 and $n <= 32 and
    (($o[0]==10 and $n>=8) or ($o[0]==172 and $o[1]>=16 and $o[1]<=31 and $n>=12) or
     ($o[0]==192 and $o[1]==168 and $n>=16)) and
    (((($o[0]*16777216+$o[1]*65536+$o[2]*256+$o[3]) / pow(2;32-$n))|floor)*pow(2;32-$n)
      == ($o[0]*16777216+$o[1]*65536+$o[2]*256+$o[3]))
  end;
def host:
  if type != "string" then false else
    text(253) and
    (if test("^[0-9.]+$") then ipv4 else
      split(".") | all(.[]; length<=63 and test("^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$"))
    end)
  end;
def endpoint_address:
  if type != "string" or (test("^[A-Za-z0-9.-]+:[0-9]{1,5}$")|not) then false else
    split(":") as $a | ($a[0]|host) and ($a[1]|tonumber) > 0 and ($a[1]|tonumber) <= 65535
  end;
def port:
  type=="string" and test("^[0-9]{1,5}$") and (tonumber)>=1 and (tonumber)<=65535;
def public_cidr:
  if type != "string" or (test("^[0-9.]+/(0|[1-9]|[12][0-9]|3[0-2])$")|not) then false else
    split("/") as $p | ($p[1]|tonumber) as $n |
    ($p[0]|split(".")|map(tonumber)) as $o |
    ($p[0]|ipv4) and $n >= 0 and $n <= 32 and
    (((($o[0]*16777216+$o[1]*65536+$o[2]*256+$o[3]) / pow(2;32-$n))|floor)*pow(2;32-$n)
      == ($o[0]*16777216+$o[1]*65536+$o[2]*256+$o[3]))
  end;
def exclusion_domain:
  if type != "string" then false else
    (if startswith("*.") then .[2:] else . end) as $name |
    ($name|host) and ($name|test("^[0-9.]+$")|not)
  end;
def exclusion_network:
  if type != "string" then false
  elif startswith("*:") then (.[2:]|port)
  elif contains("/") then public_cidr
  elif contains(":") then split(":") as $p | ($p|length)==2 and ($p[0]|ipv4) and ($p[1]|port)
  else ipv4
  end;
def exclusion: exclusion_domain or exclusion_network;
def endpoint_exclusions: if has("exclusions") then .exclusions else [] end;
def endpoint:
  require(type=="object"; "endpoint: expected an object") |
  require((keys - ["schema","hostname","addresses","username","password","protocol","certificate","dns_upstreams","exclusions","anti_dpi","mtu","wan_if"] | length)==0; "endpoint: unknown field") |
  require(.schema==1; "endpoint: unsupported schema") |
  require(.hostname|host; "endpoint: invalid TLS hostname") |
  require((.addresses|type)=="array" and (.addresses|length)>=1 and (.addresses|length)<=8 and all(.addresses[];endpoint_address); "endpoint: use host:port or IPv4:port") |
  require(.username|text(256); "endpoint: invalid username") |
  require(.password|text(1024); "endpoint: invalid password") |
  require(.protocol=="http2" or .protocol=="http3"; "endpoint: supported protocols are http2 and http3") |
  require((.certificate|type)=="string" and (.certificate|length)<=16384 and (.certificate|contains("\u0000")|not); "endpoint: invalid certificate") |
  require((.dns_upstreams|type)=="array" and (.dns_upstreams|length)<=4 and all(.dns_upstreams[];text(512) and (test("\\s")|not)); "endpoint: DNS upstreams must be an array of up to four addresses") |
  require((endpoint_exclusions|type)=="array" and (endpoint_exclusions|length)<=256 and all(endpoint_exclusions[];exclusion); "endpoint: exclusions must be supported domains, IPv4 addresses, CIDRs or ports (up to 256)") |
  require(((endpoint_exclusions|map(ascii_downcase)|unique|length))==(endpoint_exclusions|length); "endpoint: duplicate exclusions") |
  require((.anti_dpi|type)=="boolean"; "endpoint: anti_dpi must be boolean") |
  require((.mtu|type)=="number" and (.mtu|floor)==.mtu and .mtu>=1280 and .mtu<=1500; "endpoint: MTU must be an integer from 1280 to 1500") |
  require(.wan_if|type=="string" and length<=15 and test("^([A-Za-z][A-Za-z0-9_.-]*)?$"); "endpoint: invalid WAN interface") |
  .;
def network:
  require(type=="object"; "network: expected an object") |
  require((keys - ["lan_if","sources","identity"]|length)==0; "network: unknown field") |
  require((has("identity")|not) or (.identity|type=="string" and test("^[0-9a-f]{64}$")); "network: invalid topology identity") |
  require(.lan_if|type=="string" and length<=15 and test("^br[0-9]+(\\.[0-9]+)?$"); "network: expected a LAN bridge, for example br1") |
  require((.sources|type)=="array" and (.sources|length)>=1 and (.sources|length)<=32 and all(.sources[];private_cidr); "network: sources must be canonical private IPv4 CIDRs (1..32)") |
  require((.sources|unique|length)==(.sources|length); "network: duplicate sources");
def networks: if .schema==1 then [{lan_if,sources}] else .networks end;
def policy:
  require(type=="object"; "policy: expected an object") |
  require(.schema==1 or .schema==2 or .schema==3 or .schema==4; "policy: unsupported schema") |
  require((keys - (if .schema==1 then ["schema","lan_if","sources","dns_ipv4","block_ipv6_bridge","table","priority"] elif .schema==2 then ["schema","networks","dns_ipv4","block_ipv6_bridge","table","priority"] elif .schema==4 then ["schema","networks","local_access","ports","block_ipv6_bridge","table","priority"] else ["schema","networks","block_ipv6_bridge","table","priority"] end)|length)==0; "policy: unknown field") |
  require((networks|type)=="array" and ((networks|length)>=1 or (.schema==4 and ((.ports//[])|length)>0)) and (networks|length)<=16; "policy: choose 1..16 bridges") |
  require(all(networks[]; network | true); "policy: invalid network") |
  require(([networks[].lan_if]|unique|length)==(networks|length); "policy: duplicate bridge") |
  require(([networks[].sources|length]|add//0)<=32; "policy: at most 32 source rules across all bridges") |
  (if .schema==4 then
    require(((has("ports")|not) or (.ports|type=="array")) and ((.ports//[])|type)=="array" and ((.ports//[])|length)<=5 and
      all(.ports[]?;type=="object" and ((keys-["interface","lan_if","identity"])|length)==0 and
        (.interface|type=="string" and test("^eth[1-5]$")) and .lan_if=="br0" and
        (.identity|type=="string" and test("^[0-9a-f]{64}$"))) and
      ((.ports//[])|unique_by(.interface)|length)==((.ports//[])|length); "policy: invalid physical LAN ports") |
    require(all(.networks[];has("identity")); "policy: schema four requires topology identities") |
    require((.local_access|type)=="array" and (.local_access|length)<=16 and
        all(.local_access[];type=="object" and ((keys-["lan_if","destination","identity"])|length)==0 and
          (.lan_if|type=="string" and length<=15 and test("^br[0-9]+(\\.[0-9]+)?$")) and
          (.destination|private_cidr) and (.identity|type=="string" and test("^[0-9a-f]{64}$")));
        "policy: invalid local access") |
    require((.local_access|unique_by(.destination)|length)==(.local_access|length); "policy: duplicate local destination")
  else . end) |
  (if .schema<3 then
    # Validate legacy input before explicitly discarding its obsolete resolver.
    require(.dns_ipv4|ipv4; "policy: invalid legacy DNS IPv4") |
    require((.dns_ipv4|split(".")|map(tonumber)) as $o | $o[0]>0 and $o[0]<224 and $o[0]!=127 and $o[0]!=10 and ($o[0]!=172 or $o[1]<16 or $o[1]>31) and ($o[0]!=192 or $o[1]!=168) and ($o[0]!=100 or $o[1]<64 or $o[1]>127) and ($o[0]!=169 or $o[1]!=254); "policy: unusable legacy DNS destination")
  else . end) |
  require(.block_ipv6_bridge==true; "policy: bridge-wide IPv6 block must be explicitly acknowledged") |
  require(.table==871 and .priority==17100; "policy: alpha reserves table 871 and priorities 17100..17131") |
  .;
if $kind=="endpoint" then endpoint elif $kind=="policy" then policy else error("unknown validation kind") end
