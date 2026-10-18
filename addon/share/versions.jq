# Semantic ordering for official stable and nightly version labels.
def version_key:
  ltrimstr("v") | (capture("^(?<major>[0-9]+)\\.(?<minor>[0-9]+)\\.(?<patch>[0-9]+)(?:[-._](?<pre>[A-Za-z0-9._-]+))?$") // error("unsupported version")) |
  [(.major|tonumber),(.minor|tonumber),(.patch|tonumber),
   (if (.pre//"")=="" then 1 else 0 end),
   ((.pre//"")|gsub("[-_]";".")|split(".")|map(if test("^[0-9]+$") then tonumber else ascii_downcase end))];
def version_relation($installed):
  . as $candidate |
  if $candidate==("v"+$installed) then "current" else
    try (($candidate|version_key) as $a | ($installed|version_key) as $b |
      if $a>$b then "newer" elif $a<$b then "older" else "different" end) catch "unknown"
  end;
