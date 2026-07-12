#!/usr/bin/env python3
"""Sustained-rate submitter for the Leios testnet (magic 164).

Pre-signs K chains of D chained txs (each tx spends the previous change)
and submits them at a controlled rate. Chained pre-signing means 8,000 txs
only need K funding UTxOs instead of 8,000. Phases are separate so you can
pre-sign once and fire during the measurement window.

Usage:
  submitter.py fanout  --chains K --depth D          # create K head UTxOs
  submitter.py presign --chains K --depth D          # sign K*D txs -> WORK
  submitter.py submit  --rate R [--limit N]          # submit at R tx/s
  submitter.py status                                 # chain tip confirmation
"""
import argparse, json, os, subprocess, sys, time, threading, queue

CLI = "/opt/leios/bin/cardano-cli"
KEYS = "/opt/leios/keys"
WORK = "/opt/leios/submitter-work"
MAGIC = "164"
FEE = 200000          # flat 1-in-1-out fee with margin (min is ~171k)
HEAD_FLOAT = 5_000_000  # float on top of depth*FEE per chain

ENV = dict(os.environ,
           CARDANO_NODE_NETWORK_ID=MAGIC,
           CARDANO_NODE_SOCKET_PATH="/opt/leios/data/node.socket")

def cli(*args, check=True):
    r = subprocess.run([CLI, *args], env=ENV, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"cardano-cli {' '.join(args[:3])}...: {r.stderr.strip()}")
    return r

def addr():
    return open(f"{KEYS}/payment.addr").read().strip()

def utxos():
    r = cli("latest", "query", "utxo", "--address", addr(),
            "--testnet-magic", MAGIC, "--output-json")
    return json.loads(r.stdout)

def txid_of(path):
    out = cli("latest", "transaction", "txid", "--tx-file", path).stdout.strip()
    try:
        return json.loads(out)["txhash"]
    except (json.JSONDecodeError, KeyError):
        return out

def build_sign(txin, amount_out, out_prefix):
    raw, signed = f"{out_prefix}.raw", f"{out_prefix}.signed"
    cli("latest", "transaction", "build-raw",
        "--tx-in", txin, "--tx-out", f"{addr()}+{amount_out}",
        "--fee", str(FEE), "--out-file", raw)
    cli("latest", "transaction", "sign", "--tx-body-file", raw,
        "--signing-key-file", f"{KEYS}/payment.skey",
        "--testnet-magic", MAGIC, "--out-file", signed)
    os.remove(raw)
    return signed

def fanout(k, depth):
    os.makedirs(WORK, exist_ok=True)
    per_head = depth * FEE + HEAD_FLOAT
    u = utxos()
    big = max(u.items(), key=lambda e: e[1]["value"]["lovelace"])
    txin, bal = big[0], big[1]["value"]["lovelace"]
    need = k * per_head + FEE
    if bal < need:
        sys.exit(f"insufficient funds: {bal} < {need}")
    outs = []
    for _ in range(k):
        outs += ["--tx-out", f"{addr()}+{per_head}"]
    change = bal - k * per_head - FEE
    raw = f"{WORK}/fanout.raw"
    cli("latest", "transaction", "build-raw", "--tx-in", txin,
        *outs, "--tx-out", f"{addr()}+{change}",
        "--fee", str(FEE), "--out-file", raw)
    signed = f"{WORK}/fanout.signed"
    cli("latest", "transaction", "sign", "--tx-body-file", raw,
        "--signing-key-file", f"{KEYS}/payment.skey",
        "--testnet-magic", MAGIC, "--out-file", signed)
    fid = txid_of(signed)
    cli("latest", "transaction", "submit", "--tx-file", signed,
        "--testnet-magic", MAGIC)
    heads = [{"txin": f"{fid}#{i}", "amount": per_head} for i in range(k)]
    json.dump(heads, open(f"{WORK}/heads.json", "w"), indent=1)
    print(f"fanout {fid}: {k} heads of {per_head} lovelace. "
          f"No need to wait for confirmation before presigning "
          f"(mempool chaining covers it).")

def presign(k, depth):
    heads = json.load(open(f"{WORK}/heads.json"))
    assert len(heads) >= k, "fewer heads than --chains"
    t0 = time.time()
    manifest = []
    for c in range(k):
        txin, amount = heads[c]["txin"], heads[c]["amount"]
        for d in range(depth):
            amount -= FEE
            signed = build_sign(txin, amount, f"{WORK}/c{c:03d}_d{d:04d}")
            tid = txid_of(signed)
            manifest.append({"file": signed, "txid": tid, "chain": c, "depth": d})
            txin = f"{tid}#0"
        print(f"chain {c}: {depth} txs signed ({time.time()-t0:.0f}s)", flush=True)
    json.dump(manifest, open(f"{WORK}/manifest.json", "w"))
    print(f"presign total: {len(manifest)} txs in {time.time()-t0:.0f}s")

def submit(rate, limit, workers):
    manifest = json.load(open(f"{WORK}/manifest.json"))
    if limit:
        manifest = manifest[:limit]
    # order: interleave chains while respecting depth (d0 of all, then d1...)
    manifest.sort(key=lambda m: (m["depth"], m["chain"]))
    q = queue.Queue()
    for m in manifest:
        q.put(m)
    ok, err, lock = [], [], threading.Lock()
    interval = 1.0 / rate
    start = time.time()
    ticket = {"next": start}

    def worker():
        while True:
            try:
                m = q.get_nowait()
            except queue.Empty:
                return
            with lock:  # simple token bucket
                t = max(ticket["next"], time.time())
                ticket["next"] = t + interval
            time.sleep(max(0, t - time.time()))
            for attempt in range(3):
                r = cli("latest", "transaction", "submit", "--tx-file",
                        m["file"], "--testnet-magic", MAGIC, check=False)
                if r.returncode == 0:
                    with lock:
                        ok.append((time.time() - start, m["txid"]))
                    break
                if "BadInputsUTxO" in r.stderr and m["depth"] > 0:
                    time.sleep(0.5)  # parent not seen yet; retry
                    continue
                time.sleep(0.3)
            else:
                with lock:
                    err.append((m["txid"], r.stderr.strip()[:200]))

    threads = [threading.Thread(target=worker) for _ in range(workers)]
    for t in threads: t.start()
    while any(t.is_alive() for t in threads):
        time.sleep(5)
        with lock:
            n = len(ok)
        el = time.time() - start
        print(f"t+{el:.0f}s submitted={n} ({n/el:.1f} tx/s) errors={len(err)}",
              flush=True)
    for t in threads: t.join()
    el = time.time() - start
    print(f"SUBMIT DONE: {len(ok)}/{len(manifest)} in {el:.0f}s "
          f"= {len(ok)/el:.1f} tx/s sustained, {len(err)} errors")
    json.dump({"ok": ok, "err": err, "elapsed": el},
              open(f"{WORK}/submit-result.json", "w"))
    if err:
        print("first errors:", *[e[1] for e in err[:3]], sep="\n  ")

def status():
    manifest = json.load(open(f"{WORK}/manifest.json"))
    tips = {}
    for m in manifest:  # tip = deepest tx per chain
        if m["chain"] not in tips or m["depth"] > tips[m["chain"]]["depth"]:
            tips[m["chain"]] = m
    confirmed = 0
    for c, m in sorted(tips.items()):
        r = cli("latest", "query", "utxo", "--tx-in", f"{m['txid']}#0",
                "--testnet-magic", MAGIC, "--output-json")
        got = bool(json.loads(r.stdout))
        confirmed += got
        print(f"chain {c}: tip d{m['depth']} {'CONFIRMED' if got else 'pending'}")
    print(f"{confirmed}/{len(tips)} chains complete")

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("phase", choices=["fanout", "presign", "submit", "status"])
    p.add_argument("--chains", type=int, default=4)
    p.add_argument("--depth", type=int, default=10)
    p.add_argument("--rate", type=float, default=10)
    p.add_argument("--limit", type=int, default=0)
    p.add_argument("--workers", type=int, default=20)
    a = p.parse_args()
    if a.phase == "fanout": fanout(a.chains, a.depth)
    elif a.phase == "presign": presign(a.chains, a.depth)
    elif a.phase == "submit": submit(a.rate, a.limit, a.workers)
    else: status()
