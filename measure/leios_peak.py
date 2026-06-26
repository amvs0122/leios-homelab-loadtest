#!/usr/bin/env python3
import json, statistics
from collections import defaultdict
LOG="/opt/leios/data/node.log"
eb_bits={}; eb_bytes={}; eb_slot={}
for raw in open(LOG,"rb"):
    if b"Leios" not in raw: continue
    try: d=json.loads(raw)
    except: continue
    ns=d.get("ns",""); msg=d.get("data",{}).get("msg",{})
    if ns.endswith("Receive.Block"):
        h=msg.get("ebHash"); s=msg.get("ebBytesSize")
        if h and s is not None: eb_bytes[h]=s
    elif ns.endswith("Receive.BlockTxs"):
        h=msg.get("ebHash"); bm=msg.get("bitmaps")
        if h and bm:
            w=eb_bits.setdefault(h,{})
            for e in bm:
                i,hx=e.split(":"); w[int(i)]=w.get(int(i),0)|int(hx,16)
    elif ns.endswith("Send.BlockRequest"):
        h=msg.get("ebHash"); s=msg.get("ebSlot")
        if h and s is not None: eb_slot[h]=s
eb_tx={h:sum(bin(m).count("1") for m in w.values()) for h,w in eb_bits.items()}
# txs por slot
tx_by_slot=defaultdict(int); bytes_by_slot=defaultdict(int)
for h,n in eb_tx.items():
    if h in eb_slot:
        tx_by_slot[eb_slot[h]]+=n; bytes_by_slot[eb_slot[h]]+=eb_bytes.get(h,0)
if not tx_by_slot: print("sin datos"); exit()
s0=min(tx_by_slot); s1=max(tx_by_slot)
arr_tx=[tx_by_slot.get(s,0) for s in range(s0,s1+1)]
arr_by=[bytes_by_slot.get(s,0) for s in range(s0,s1+1)]
import itertools
def peak(arr,W):
    if len(arr)<W: W=len(arr)
    cur=sum(arr[:W]); best=cur; bi=0
    for i in range(W,len(arr)):
        cur+=arr[i]-arr[i-W]
        if cur>best: best=cur; bi=i-W+1
    return best,W,s0+bi
print(f"datos: {len(eb_tx)} EBs, slots {s0}-{s1} ({s1-s0}s de cadena)\n")
print(f"{'ventana':>10} | {'TPS pico':>9} | {'MB/s pico':>9} | inicia en slot")
print("-"*55)
for W in (10,30,60,300,600):
    bt,w,sl=peak(arr_tx,W); bb,_,_=peak(arr_by,W)
    print(f"{W:>8}s  | {bt/w:>8.1f} | {bb/w/1e6:>8.3f}  | {sl}")
print(f"\nEB individual mas grande: {max(eb_tx.values()):,} txs, {max(eb_bytes.values()):,} bytes")
allt=[v for v in eb_tx.values()]
print(f"distribucion tx/EB: p50={int(statistics.median(allt))} p90={sorted(allt)[int(len(allt)*0.9)]} max={max(allt)}")
