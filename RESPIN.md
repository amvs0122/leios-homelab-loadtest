# Surviving a testnet respin

The Leios testnet (Musashi Dōjō) gets **respun without notice** — a new genesis wipes the chain, your pool registration, and your faucet funds. Releases (`prototype-2026wNN`) ship almost weekly; not every release is a respin, but when one is, your node dies quietly. This is the recovery runbook, learned the hard way in July 2026 (genesis `2026-07-01`, recovered on `prototype-2026w28`).

## Symptom

Your node is `active` but stuck at a low slot with ~0% sync, and ChainSync keeps rejecting the bootstrap relay's headers:

```
HeaderError ... NoCounterForKeyHashOCERT (KeyHash ...)
```

That error means the header was forged by a pool **your ledger has never seen** — i.e. you are validating a different chain: new genesis, respin.

A quick sanity check that doesn't need any changelog: multiply the remote tip's slot by the slot length and add it to *your* `systemStart`. If the resulting wall-clock time is in the past, the remote chain started later than your genesis says — it's a respin, and the arithmetic even tells you roughly when.

## Recovery

Binaries and configs **must move together** — the testnet configs (including genesis) live in the repo at the release tag, and a node updated to new binaries but old genesis is just as stuck as before (ask me how I know).

1. **Binaries** from the release tarball (verify the `.sha256`).
2. **Configs**: `git checkout prototype-2026wNN` in your `ouroboros-leios` clone (or re-download `testnet/config/`).
3. **Wipe the chain DB** (`db/`, plus `leios.db*`). Everything there belongs to the dead chain. Resync from genesis is fast while the chain is young (~4 min for 10 days of chain on 4 cores).
4. **Reset the opcert counter to 0** — the new ledger has no history for your cold key:
   ```bash
   cardano-cli latest node new-counter \
     --cold-verification-key-file cold.vkey \
     --counter-value 0 \
     --operational-certificate-issue-counter-file cold.counter
   ```
5. **Issue a fresh opcert with the *current* KES period** — never hardcode it; the old chain's period is invalid on the new one:
   ```bash
   SLOT=$(cardano-cli latest query tip --testnet-magic 164 | jq -r .slot)
   SPKP=$(jq -r .slotsPerKESPeriod shelley-genesis.json)
   cardano-cli latest node issue-op-cert ... --kes-period $((SLOT / SPKP))
   ```
6. **Re-register the pool.** Your cold keys survive, so the pool id is the same — only the on-chain state is gone. Faucet funds (mind the deposits: 500 ADA pool + 2 ADA stake key), then one tx with stake-reg + pool-reg + delegation certs.
7. **Faucet `delegate`** to get real stake: it wants the pool id in **bech32** (`pool1…`); the hex form is rejected with a cryptic `StringToDecodeTooShort`. Leader election picks it up ~2 epochs later.
8. Restart the node so it loads the new opcert.

## Two self-inflicted bugs worth sharing

- **`FeeTooSmallUTxO` on the registration tx.** Not a CLI bug: our `build-raw` draft used `--tx-out ADDR+0` as the change placeholder. `calculate-min-fee` measures the draft you give it, and `0` encodes 8 CBOR bytes shorter than the real change amount — 8 bytes × `minFeeA` 44 = 352 lovelace short. Use a realistic placeholder amount, or add a small buffer to the fee.
- **Don't benchmark on release day.** We measured external-tx inclusion latency of 4–30 minutes (vs ~34 s a release earlier) and nearly reported it as a fairness regression — it vanished ~2 h later. The release had shipped *that afternoon* and the testnet's own fleet was mid-upgrade. Performance findings on a shared testnet need a release-calendar check and a second day of data.
