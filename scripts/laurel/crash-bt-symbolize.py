#!/usr/bin/env python3
"""crash-bt-symbolize.py LOG NAME...: the kernel's `CRASH NAME bt ...` lines of a USB log, against the 23F84 dyld cache: the most common stacks of each job. NAME: as in the log (16 characters).
Uses dsc-image.py; cache in ~/op10-apple/ios26/23F84-n104ap/tree/cache. Run with python3 -I from the repo root. Host only."""
import re,subprocess,bisect,collections,sys
DIR="/home/akshay/op10-apple/ios26/23F84-n104ap/tree/cache"
T="scripts/laurel/dsc-image.py"
imgs=[]
for l in subprocess.run(["python3","-I",T,DIR,"images"],capture_output=True,text=True).stdout.splitlines():
    a,p=l.split(None,1); imgs.append((int(a,16),p))
imgs.sort(); keys=[a for a,_ in imgs]
def img(a):
    i=bisect.bisect_right(keys,a)-1
    return imgs[i][1] if i>=0 else None
syms={}
def sym(a):
    p=img(a)
    if p is None: return hex(a)
    if p not in syms:
        tab=[]
        for l in subprocess.run(["python3","-I",T,DIR,"syms",p],capture_output=True,text=True).stdout.splitlines():
            q=l.split(None,2)
            if len(q)==3:
                try: tab.append((int(q[0],16),q[2]))
                except: pass
        tab.sort(); syms[p]=(tab,[x for x,_ in tab])
    tab,k=syms[p]
    i=bisect.bisect_right(k,a)-1
    return p.split('/')[-1]+':'+(tab[i][1][:60] if i>=0 else '?')
log=sys.argv[1]
names=sys.argv[2:]
for name in names:
    st=collections.Counter();slide=None
    pcs=[]
    for l in open(log,errors='replace'):
        m=re.search(r'CRASH '+name+r'\[\d+\] sig \d+ code \S+ sub \S+ slide (0x[0-9a-f]+)',l)
        if m: slide=int(m.group(1),16)
        m=re.search(r'CRASH '+name+r' bt (.*)',l)
        if m and slide is not None:
            fr=[int(x,16)-slide for x in m.group(1).split()]
            pcs.append(fr)
    print("==",name,len(pcs),"stacks")
    agg=collections.Counter()
    for fr in pcs[:60]:
        agg[tuple(sym(a) for a in fr[:6])]+=1
    for k,n in agg.most_common(5):
        print(n); [print("   ",x) for x in k]
