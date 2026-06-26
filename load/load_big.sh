#!/bin/bash
# Uso: load_big.sh N
cd /opt/leios/load
export PATH=/opt/leios/bin:$PATH
export CARDANO_NODE_NETWORK_ID=164
export CARDANO_NODE_SOCKET_PATH=/opt/leios/data/node.socket
ADDR=$(cat /opt/leios/keys/payment.addr)
SKEY=/opt/leios/keys/payment.skey
N=${1:-1000}
FEE=200000; OUTV=$((5000000-FEE))
mp(){ curl -s http://127.0.0.1:12798/metrics | awk '/txsInMempool_int [0-9]/{print $2}'; }

echo "===== OBJETIVO: $N tx ====="
# --- Fase 1: fan-out en rondas hasta tener N UTxOs de 5 ADA ---
have(){ cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json | jq '[to_entries[]|select(.value.value.lovelace==5000000)]|length'; }
while [ "$(have)" -lt "$N" ]; do
  CUR=$(have); NEED=$((N-CUR)); CHUNK=$((NEED>180?180:NEED))
  BIG=$(cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json | jq -r 'to_entries|max_by(.value.value.lovelace)|.key')
  OUTS=""; for j in $(seq 1 $CHUNK); do OUTS="$OUTS --tx-out ${ADDR}+5000000"; done
  cardano-cli dijkstra transaction build --tx-in "$BIG" $OUTS --change-address "$ADDR" --testnet-magic 164 --out-file fo.raw >/dev/null
  cardano-cli latest transaction sign --tx-body-file fo.raw --signing-key-file "$SKEY" --testnet-magic 164 --out-file fo.signed
  cardano-cli latest transaction submit --tx-file fo.signed --testnet-magic 164 >/dev/null
  echo "fan-out +$CHUNK (tenia $CUR)... esperando"
  for k in $(seq 1 30); do [ "$(have)" -ge $((CUR+CHUNK)) ] && break; sleep 3; done
done
echo "UTxOs de 5 ADA listos: $(have)"

# --- Fase 2: pre-build + sign N tx ---
rm -rf txs; mkdir -p txs
mapfile -t U < <(cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json | jq -r 'to_entries[]|select(.value.value.lovelace==5000000)|.key')
i=0; for u in "${U[@]}"; do [ $i -ge $N ] && break
  cardano-cli latest transaction build-raw --tx-in "$u" --tx-out "$ADDR+$OUTV" --fee $FEE --out-file txs/$i.raw 2>/dev/null
  cardano-cli latest transaction sign --tx-body-file txs/$i.raw --signing-key-file "$SKEY" --testnet-magic 164 --out-file txs/$i.signed 2>/dev/null
  i=$((i+1)); done
echo "pre-firmadas: $i tx"

# --- Fase 3: BURST con timing ms ---
echo "mempool antes: $(mp)"
OK=0; T0=$(date +%s%3N)
for f in txs/*.signed; do cardano-cli latest transaction submit --tx-file "$f" --testnet-magic 164 >/dev/null 2>&1 && OK=$((OK+1)); done
T1=$(date +%s%3N); DUR=$((T1-T0))
echo "===== BURST: $OK/$i enviadas en $((DUR/1000)).$((DUR%1000))s -> $(( OK*1000 / (DUR/1000>0?DUR/1000:1) ))/s submit (cli-limited) ====="
echo "mempool tras burst: $(mp)"

# --- Fase 4: inclusion + drenaje mempool ---
START=$(date +%s); PEAK=0
for s in $(seq 1 80); do
  M=$(mp); [ "${M:-0}" -gt "$PEAK" ] && PEAK=$M
  REM=$(cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json | jq '[to_entries[]|select(.value.value.lovelace==5000000)]|length')
  EL=$(( $(date +%s) - START ))
  echo "  t+${EL}s: mempool=$M  sin_confirmar=$REM/$i"
  [ "$REM" -eq 0 ] && { echo "===== TODAS confirmadas en ~${EL}s · mempool pico=$PEAK ====="; break; }
  sleep 3
done
