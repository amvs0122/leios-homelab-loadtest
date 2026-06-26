#!/bin/bash
cd /opt/leios/load
export PATH=/opt/leios/bin:$PATH
export CARDANO_NODE_NETWORK_ID=164
export CARDANO_NODE_SOCKET_PATH=/opt/leios/data/node.socket
ADDR=$(cat /opt/leios/keys/payment.addr)
SKEY=/opt/leios/keys/payment.skey
FEE=200000; OUTV=$((5000000-FEE))
rm -rf txs; mkdir -p txs

mapfile -t UTXOS < <(cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json | jq -r 'to_entries[]|select(.value.value.lovelace==5000000)|.key')
echo "UTxOs a gastar: ${#UTXOS[@]}"

i=0
for u in "${UTXOS[@]}"; do
  cardano-cli latest transaction build-raw --tx-in "$u" --tx-out "$ADDR+$OUTV" --fee $FEE --out-file txs/$i.raw 2>/dev/null
  cardano-cli latest transaction sign --tx-body-file txs/$i.raw --signing-key-file "$SKEY" --testnet-magic 164 --out-file txs/$i.signed 2>/dev/null
  i=$((i+1))
done
echo "pre-construidas+firmadas: $i tx"

echo "mempool antes: $(curl -s http://127.0.0.1:12798/metrics | grep -iE 'mempooltxs|mempoolbytes|txsinmempool' | tr '\n' ' ')"

OK=0; T0=$(date +%s.%N)
for f in txs/*.signed; do
  cardano-cli latest transaction submit --tx-file "$f" --testnet-magic 164 >/dev/null 2>&1 && OK=$((OK+1))
done
T1=$(date +%s.%N); DUR=$(echo "$T1 - $T0" | bc)
echo "=== BURST: $OK/$i enviadas en ${DUR}s -> $(echo "scale=1; $OK/$DUR" | bc) tx/s (submit, limitado por cli) ==="
echo "mempool justo despues: $(curl -s http://127.0.0.1:12798/metrics | grep -iE 'mempooltxs|mempoolbytes|txsinmempool' | tr '\n' ' ')"

echo "=== confirmacion (UTxOs de 5 ADA consumiendose) ==="
START=$(date +%s)
for s in $(seq 1 80); do
  REM=$(cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json | jq '[to_entries[]|select(.value.value.lovelace==5000000)]|length')
  EL=$(( $(date +%s) - START ))
  echo "  t+${EL}s: quedan $REM / $i sin confirmar"
  [ "$REM" -eq 0 ] && { echo "=== TODAS las $i tx confirmadas en ~${EL}s ==="; break; }
  sleep 3
done
