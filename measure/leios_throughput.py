#!/usr/bin/env python3
import json, sys, statistics
LOG="/opt/leios/data/node.log"
SLOTLEN=1.0  # shelley-genesis slotLength

eb_bits={}   # ebHash -> {wordIdx: mask}  (union of inclusion bitmaps)
eb_bytes={}  # ebHash -> size
eb_slot={}   # ebHash -> slot

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
                i,hx=e.split(":"); i=int(i); m=int(hx,16)
                w[i]=w.get(i,0)|m
    elif ns.endswith("Send.BlockRequest"):
        h=msg.get("ebHash"); s=msg.get("ebSlot")
        if h and s is not None: eb_slot[h]=s

# tx count per EB
eb_tx={h:sum(bin(m).count("1") for m in w.values()) for h,w in eb_bits.items()}

# EBs usable = tienen txs y slot
ebs=[(eb_slot[h], eb_tx[h], eb_bytes.get(h,0)) for h in eb_tx if h in eb_slot]
ebs.sort()
if not ebs:
    print("sin EBs con slot+txs todavia"); sys.exit()

def report(name, rows):
    if not rows: print(f"\n[{name}] sin datos"); return
    s0,s1=rows[0][0],rows[-1][0]
    span=max(1,(s1-s0))*SLOTLEN
    txs=sum(r[1] for r in rows); byts=sum(r[2] for r in rows)
    txcounts=[r[1] for r in rows]; szs=[r[2] for r in rows]
    print(f"\n=== {name} ===")
    print(f"  rango slots:     {s0} -> {s1}  ({s1-s0} slots = {span:.0f}s de cadena)")
    print(f"  endorser blocks: {len(rows)}  ({len(rows)/(span/60):.1f} EB/min, ~1 cada {span/len(rows):.1f}s)")
    print(f"  total txs:       {txs:,}")
    print(f"  >> TPS efectivo: {txs/span:.1f} tx/s")
    print(f"  bytes en EBs:    {byts/1e6:.2f} MB  ({byts/span/1024:.1f} KB/s, {byts/span*60/1e6:.2f} MB/min)")
    print(f"  tx/EB:           min {min(txcounts)}  mediana {int(statistics.median(txcounts))}  media {statistics.mean(txcounts):.0f}  max {max(txcounts)}")
    print(f"  bytes/EB:        mediana {int(statistics.median(szs)):,}  max {max(szs):,}")

report("GLOBAL (toda la data descargada)", ebs)
# ventana reciente: ultimos 600 slots de cadena
last=ebs[-1][0]
report("VENTANA RECIENTE (ultimos 600 slots de cadena)", [r for r in ebs if r[0]>=last-600])

# contexto Praos
print(f"\n=== CONTEXTO ===")
print(f"  Praos: 1 ranking block cada ~20s (activeSlotsCoeff 0.05, slot 1s)")
print(f"  Mainnet Cardano hoy sostiene ~3-10 TPS pico. Leios mete los tx en EBs paralelos a los RB.")
