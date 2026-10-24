#!/usr/bin/env python3
"""Atomic ebtables command recorder, not a kernel or packet simulator."""
import json, os, shlex, sys
from pathlib import Path
base=Path(os.environ['TT_MOCK_NET']); live=base/'ethernet.json'; args=sys.argv[1:]
def option(k,d=None): return args[args.index(k)+1] if k in args else d
table=option('-t','filter'); file=Path(option('--atomic-file',str(live)))
state=json.loads((file if file.exists() and file.stat().st_size else live).read_text()) if (file.exists() and file.stat().st_size) or live.exists() else {'broute':{'BROUTING':[]},'filter':{},'nat':{}}
with (base/'ethernet-calls.jsonl').open('a') as out: out.write(json.dumps(args)+'\n')
def finish(code=0):
 if code==0: file.write_text(json.dumps(state))
 sys.exit(code)
if os.environ.get('TT_EB_FAIL') and os.environ['TT_EB_FAIL'] in shlex.join(args): sys.exit(9)
if '--atomic-save' in args: finish()
if '--atomic-commit' in args: live.write_text(json.dumps(state));sys.exit(0)
chains=state.setdefault(table,{})
for op in ('-L','-N','-F','-X','-A','-I','-D'):
 if op not in args: continue
 pos=args.index(op); chain=args[pos+1] if len(args)>pos+1 and not args[pos+1].startswith('-') else None
 if op=='-L':
  if '--atomic-file' not in args and os.environ.get('TT_EB_RACE') and not (base/'race-fired').exists():
   state['broute']['BROUTING'].append(['-i','eth3','-j','ACCEPT']);live.write_text(json.dumps(state));(base/'race-fired').touch()
  if chain and chain not in chains: sys.exit(1)
  for c,rules in chains.items():
   if chain and c!=chain: continue
   # Real Merlin legacy ebtables prints bare jumps without trailing space.
   # Include user-chain declarations as --Lx does, including empty chains.
   if c not in ('BROUTING','PREROUTING','POSTROUTING','INPUT','FORWARD','OUTPUT'):
    print(shlex.join(['ebtables','-t',table,'-N',c]))
   for rule in rules: print(shlex.join(['ebtables','-t',table,'-A',c,*rule]))
  sys.exit(0)
 if op=='-N':
  if chain in chains: sys.exit(1)
  chains[chain]=[];finish()
 if chain not in chains: sys.exit(1)
 if op=='-F': chains[chain]=[];finish()
 if op=='-X':
  if any('-j' in rule and rule[rule.index('-j')+1]==chain for rules in chains.values() for rule in rules): sys.exit(1)
  del chains[chain];finish()
 body=args[pos+(3 if op=='-I' else 2):]
 if op=='-A': chains[chain].append(body);finish()
 if op=='-I': chains[chain].insert(0,body);finish()
 if op=='-D':
  if body not in chains[chain]: sys.exit(1)
  chains[chain].remove(body);finish()
sys.exit(2)
