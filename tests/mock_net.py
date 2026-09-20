#!/usr/bin/env python3
"""A command recorder/state model, NOT a kernel or a packet-flow simulator."""
from pathlib import Path
import json
import os
import sys

base=Path(os.environ['TT_MOCK_NET'])
statefile=base/'state.json'
state=json.loads(statefile.read_text()) if statefile.exists() else {'chains':{},'rules':[],'routes':{}}
name=Path(sys.argv[0]).name
args=sys.argv[1:]
stdin=sys.stdin.read() if name.endswith('-restore') else ''
with (base/'calls.jsonl').open('a') as out: out.write(json.dumps({'program':name,'argv':args,'stdin':stdin})+'\n')

def done(code=0,text=''):
    statefile.write_text(json.dumps(state))
    if text: print(text)
    raise SystemExit(code)

def opt(items,key,default=None):
    return items[items.index(key)+1] if key in items else default

def keychain(program,table,chain):return program+':'+table+':'+chain

def filter_command(program,table,items):
    command=items[0]
    chain=items[1]
    key=keychain(program,table,chain)
    if command=='-N':state['chains'].setdefault(key,[]);return 0
    if command=='-F':
        if key not in state['chains']:return 1
        state['chains'][key]=[];return 0
    if command=='-X':
        if key not in state['chains']:return 1
        del state['chains'][key];return 0
    if command=='-S':return 0 if key in state['chains'] else 1
    body=items[2:]
    if command=='-I':body=items[3:]
    values=state['chains'].setdefault(key,[])
    if command=='-C':return 0 if body in values else 1
    if command=='-D':
        if body not in values:return 1
        values.remove(body);return 0
    if command=='-I':values.insert(0,body);return 0
    if command=='-A':values.append(body);return 0
    return 2

if os.environ.get('TT_MOCK_FAIL') and os.environ['TT_MOCK_FAIL'] in name+' '+' '.join(args):done(9)
if name=='fc':
    done(0 if len(args)==3 and args[:2]==['flush','--if'] else 2)
if name.endswith('-restore'):
    program=name.removesuffix('-restore');table='filter'
    for line in stdin.splitlines():
        if line.startswith('*'):table=line[1:]
        elif line.startswith(':'):state['chains'].setdefault(keychain(program,table,line[1:].split()[0]),[])
        elif line.startswith('-'):
            result=filter_command(program,table,line.split())
            if result:done(result)
    done()
if name in ('iptables','ip6tables'):
    table=opt(args,'-t','filter')
    if '-t' in args:
        pos=args.index('-t');args=args[:pos]+args[pos+2:]
    done(filter_command(name,table,args))
if name=='ip':
    if args[:2]==['link','show']:done(1)
    if args[:3]==['-4','rule','show']:
        text='\n'.join(f'{r[0]}: from {r[1]} iif {r[2]} lookup {r[3]}' for r in state['rules'])
        done(text=text)
    if args[:2]==['-4','rule']:
        rule=[opt(args,'pref'),opt(args,'from'),opt(args,'iif'),opt(args,'lookup')]
        if args[2]=='del':
            if rule not in state['rules']:done(2)
            state['rules'].remove(rule);done()
        if args[2]=='add':
            if rule in state['rules']:done(2)
            state['rules'].append(rule);done()
    if args[:3]==['-4','route','show']:
        table=opt(args,'table')
        done(text='\n'.join(' '.join(a) for a in state['routes'].values() if opt(a,'table')==table))
    if args[:2]==['-4','route']:
        key=opt(args,'table')+':'+opt(args,'metric','0')
        if args[3] not in ('default', 'prohibit'): key += ':'+args[3]
        if args[2]=='replace':state['routes'][key]=args;done()
        if args[2]=='del':
            if key not in state['routes']:done(2)
            del state['routes'][key];done()
done(2)
