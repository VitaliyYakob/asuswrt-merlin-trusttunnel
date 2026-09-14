# stdin: one IPv4 address/prefix per line, from ip -4 -o address output.
def canonical_cidr:
  if test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]{1,2}$") then
    split("/") as $parts |
    ($parts[0]|split(".")|map(tonumber)) as $o |
    ($parts[1]|tonumber) as $prefix |
    if $prefix>=0 and $prefix<=32 and all($o[]; .>=0 and .<=255) then
      pow(2;32-$prefix) as $size |
      (((($o[0]*16777216+$o[1]*65536+$o[2]*256+$o[3])/$size)|floor)*$size) as $n |
      [($n/16777216|floor), (($n/65536|floor)%256), (($n/256|floor)%256), ($n%256)] |
      (map(tostring)|join(".")) + "/" + ($prefix|tostring)
    else empty end
  else empty end;
{lan_if:$interface,sources:([inputs|canonical_cidr]|unique)}
