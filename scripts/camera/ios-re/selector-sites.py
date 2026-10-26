#!/usr/bin/env python3
# IOConnectCall* call sites of an `ipsw dyld disass` listing: selector (x1) and the scalar/struct
# arguments (x3/x5/x7) per caller. Used by scripts/camera/ios-re.sh. Run with python3 -I.
import re,sys
f=sys.argv[1]
lines=open(f,errors='replace').read().split('\n')
fn=None;hist=[]
out=[]
ins=re.compile(r'^0x[0-9a-f]+:\s+(?:[0-9a-f]{2} ){4}\s*(\S+)\s*(.*)$')
def val(reg,hist):
    # find last write to reg
    for t in reversed(hist[-45:]):
        m=re.match(r'(mov|movz)\s+(?:w|x)(\d+),\s*#(-?0x[0-9a-f]+|-?\d+)',t)
        if m and ('w'+m.group(2)==reg or 'x'+m.group(2)==reg or m.group(2)==reg[1:]):
            return int(m.group(3),0)
        m=re.match(r'(\w+)\s+[wx](\d+),',t)
        if m and m.group(2)==reg[1:] and m.group(1) not in ('str','stp','cmp','tst','cbz','cbnz','b','bl'):
            return '?'+t.strip()[:40]
    return None
for l in lines:
    if l and l[0]=='_' and l.endswith(':'):
        fn=l[:-1];hist=[];continue
    m=ins.match(l)
    if not m: continue
    t=m.group(1)+' '+m.group(2)
    mm=re.match(r'bl\s+(_IOConnectCall\w+)_stub',t)
    if mm:
        a=l.split(':')[0]
        r={k:val(k,hist) for k in ('x1','x3','x5','x7')}
        out.append((fn,a,mm.group(1),r, [h for h in hist[-60:] if re.match(r'(mov|movz|add|sub)\s+x?[wx]?[2-7],',h)][-8:]))
    elif m.group(1)=='bl' :
        hist.append(t) if False else hist.append(t)
    else: hist.append(t)
    if m.group(1)=='bl': hist=[h for h in hist]  # keep
for o in out:
    print(o[1],o[2][14:],'sel=',o[3]['x1'],'x3=',o[3]['x3'],'x5=',o[3]['x5'],'x7=',o[3]['x7'],'|',o[0][:90])
