#!/bin/bash
# Test SOSTENIDO: inyecta a ritmo fijo durante D segundos y mide mempool + confirmacion.
# Uso: load_sustained.sh RATE DURATION   (ej: 10 tx/s durante 180s = 1800 tx)
cd /opt/leios/load
export PATH=/opt/leios/bin:$PATH
export CARDANO_NODE_NETWORK_ID=164
export CARDANO_NODE_SOCKET_PATH=/opt/leios/data/node.socket
ADDR=$(cat /opt/leios/keys/payment.addr)
SKEY=/opt/leios/keys/payment.skey
RATE=${1:-10}; DUR=${2:-180}; TOTAL=$((RATE*DUR))
VAL=3000000; FEE=200000; OUTV=$((VAL-FEE))   # UTxOs de 3 ADA (distintos del burst)
mp(){ curl -s http://127.0.0.1:12798/metrics | awk '/txsInMempool_int [0-9]/{print $2}'; }
have(){ cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json | jq "[to_entries[]|select(.value.value.lovelace==$VAL)]|length"; }

echo "===== SOSTENIDO: $RATE tx/s x ${DUR}s = $TOTAL tx ====="

# --- Fase 1: fan-out a TOTAL UTxOs de 3 ADA (rondas de 180) ---
while [ "$(have)" -lt "$TOTAL" ]; do
  CUR=$(have); NEED=$((TOTAL-CUR)); CHUNK=$((NEED>180?180:NEED))
  BIG=$(cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json | jq -r 'to_entries|max_by(.value.value.lovelace)|.key')
  OUTS=""; for j in $(seq 1 $CHUNK); do OUTS="$OUTS --tx-out ${ADDR}+${VAL}"; done
  cardano-cli dijkstra transaction build --tx-in "$BIG" $OUTS --change-address "$ADDR" --testnet-magic 164 --out-file fo.raw >/dev/null
  cardano-cli latest transaction sign --tx-body-file fo.raw --signing-key-file "$SKEY" --testnet-magic 164 --out-file fo.signed
  cardano-cli latest transaction submit --tx-file fo.signed --testnet-magic 164 >/dev/null
  echo "fan-out +$CHUNK (tenia $CUR)"; for k in $(seq 1 30); do [ "$(have)" -ge $((CUR+CHUNK)) ] && break; sleep 3; done
done
echo "pool listo: $(have) UTxOs de 3 ADA"

# --- Fase 2: pre-firmar TOTAL tx ---
rm -rf stx; mkdir -p stx
mapfile -t U < <(cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json | jq -r "to_entries[]|select(.value.value.lovelace==$VAL)|.key")
i=0; for u in "${U[@]}"; do [ $i -ge $TOTAL ] && break
  cardano-cli latest transaction build-raw --tx-in "$u" --tx-out "$ADDR+$OUTV" --fee $FEE --out-file stx/$i.raw 2>/dev/null
  cardano-cli latest transaction sign --tx-body-file stx/$i.raw --signing-key-file "$SKEY" --testnet-magic 164 --out-file stx/$i.signed 2>/dev/null
  i=$((i+1)); done
echo "pre-firmadas: $i tx"

# --- Fase 3: muestreador de mempool en background ---
( for t in $(seq 1 $((DUR+90))); do echo "$(date +%s) mempool=$(mp)"; sleep 2; done ) > sustained_mp.log &
SAMPLER=$!

# --- Fase 4: inyeccion paceada (RATE tx por segundo) ---
echo "--- inyectando $RATE tx/s durante ${DUR}s ---"
idx=0; SENT=0; T0=$(date +%s)
for sec in $(seq 1 $DUR); do
  SECEND=$(( $(date +%s%3N) + 1000 ))
  for r in $(seq 1 $RATE); do
    [ $idx -ge $TOTAL ] && break
    cardano-cli latest transaction submit --tx-file stx/$idx.signed --testnet-magic 164 >/dev/null 2>&1 &
    idx=$((idx+1)); SENT=$((SENT+1))
  done
  wait
  NOW=$(date +%s%3N); [ $NOW -lt $SECEND ] && sleep $(awk "BEGIN{print ($SECEND-$NOW)/1000}")
  [ $((sec % 15)) -eq 0 ] && echo "  +${sec}s enviadas=$SENT mempool=$(mp)"
done
T1=$(date +%s); WALL=$((T1-T0))
echo "===== INYECTADAS $SENT tx en ${WALL}s -> $((SENT/WALL)) tx/s sostenido (objetivo $RATE) ====="

# --- Fase 5: drenaje + confirmacion ---
for s in $(seq 1 60); do
  REM=$(have); M=$(mp); echo "  drenaje t+$((s*3))s: mempool=$M sin_confirmar=$REM"
  [ "$REM" -eq 0 ] && { echo "TODO confirmado"; break; }; sleep 3
done
kill $SAMPLER 2>/dev/null
echo "=== mempool pico durante la prueba: $(awk -F= '{print $2}' sustained_mp.log | sort -n | tail -1) ==="
