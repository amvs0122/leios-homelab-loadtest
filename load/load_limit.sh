#!/bin/bash
# STRESS: flood con paralelismo maximo para encontrar el limite de NUESTRO nodo.
# Uso: load_limit.sh NPOOL PAR   (ej: 3000 tx, 80 submits en paralelo)
cd /opt/leios/load
export PATH=/opt/leios/bin:$PATH
export CARDANO_NODE_NETWORK_ID=164
export CARDANO_NODE_SOCKET_PATH=/opt/leios/data/node.socket
ADDR=$(cat /opt/leios/keys/payment.addr)
SKEY=/opt/leios/keys/payment.skey
N=${1:-3000}; PAR=${2:-80}
VAL=2000000; FEE=200000; OUTV=$((VAL-FEE))   # UTxOs de 2 ADA
mp(){ curl -s http://127.0.0.1:12798/metrics | awk '/txsInMempool_int [0-9]/{print $2}'; }
mpb(){ curl -s http://127.0.0.1:12798/metrics | awk '/mempoolBytes_int [0-9]/{print $2}'; }
have(){ cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json | jq "[to_entries[]|select(.value.value.lovelace==$VAL)]|length"; }

echo "===== STRESS: $N tx, paralelismo $PAR ====="
# Fase 1: fan-out a N UTxOs de 2 ADA
while [ "$(have)" -lt "$N" ]; do
  CUR=$(have); NEED=$((N-CUR)); CHUNK=$((NEED>180?180:NEED))
  BIG=$(cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json | jq -r 'to_entries|max_by(.value.value.lovelace)|.key')
  OUTS=""; for j in $(seq 1 $CHUNK); do OUTS="$OUTS --tx-out ${ADDR}+${VAL}"; done
  cardano-cli dijkstra transaction build --tx-in "$BIG" $OUTS --change-address "$ADDR" --testnet-magic 164 --out-file fl.raw >/dev/null
  cardano-cli latest transaction sign --tx-body-file fl.raw --signing-key-file "$SKEY" --testnet-magic 164 --out-file fl.signed
  cardano-cli latest transaction submit --tx-file fl.signed --testnet-magic 164 >/dev/null 2>&1
  echo "fan-out +$CHUNK (tenia $CUR)"; for k in $(seq 1 40); do [ "$(have)" -ge $((CUR+CHUNK)) ] && break; sleep 3; done
done
echo "pool: $(have) UTxOs"

# Fase 2: pre-firmar
rm -rf ltx; mkdir -p ltx
mapfile -t U < <(cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json | jq -r "to_entries[]|select(.value.value.lovelace==$VAL)|.key")
i=0; for u in "${U[@]}"; do [ $i -ge $N ] && break
  cardano-cli latest transaction build-raw --tx-in "$u" --tx-out "$ADDR+$OUTV" --fee $FEE --out-file ltx/$i.raw 2>/dev/null
  cardano-cli latest transaction sign --tx-body-file ltx/$i.raw --signing-key-file "$SKEY" --testnet-magic 164 --out-file ltx/$i.signed 2>/dev/null
  i=$((i+1)); done
echo "pre-firmadas: $i tx"

# Fase 3: muestreador rapido (mempool + load) en background
( for t in $(seq 1 120); do echo "$(date +%s) txs=$(mp) bytes=$(mpb) load=$(awk '{print $1}' /proc/loadavg)"; sleep 1; done ) > limit_samples.log &
SAMP=$!

# Fase 4: FLOOD con paralelismo
echo "mempool antes: $(mp) tx / $(mpb) bytes"
T0=$(date +%s%3N)
ls ltx/*.signed | xargs -P $PAR -I{} sh -c 'cardano-cli latest transaction submit --tx-file {} --testnet-magic 164 >/dev/null 2>>/opt/leios/load/limit_err.log && echo ok >> /opt/leios/load/limit_ok.log'
T1=$(date +%s%3N); DUR=$((T1-T0))
OK=$(wc -l < /opt/leios/load/limit_ok.log 2>/dev/null || echo 0)
ERR=$(grep -c "Error" /opt/leios/load/limit_err.log 2>/dev/null || echo 0)
echo "===== FLOOD: $OK ok / $ERR err de $N en $((DUR/1000)).$((DUR%1000))s ====="
[ $((DUR/1000)) -gt 0 ] && echo "ritmo submit: $((OK / (DUR/1000) )) tx/s" || echo "ritmo: <1s"

# Fase 5: pico + drenaje
sleep 3; kill $SAMP 2>/dev/null
echo "=== PICO mempool: $(awk '{print $2}' limit_samples.log | sed 's/txs=//' | sort -n | tail -1) tx / $(awk '{print $3}' limit_samples.log | sed 's/bytes=//' | sort -n | tail -1) bytes ==="
echo "=== LOAD avg pico (4 cores): $(awk '{print $4}' limit_samples.log | sed 's/load=//' | sort -n | tail -1) ==="
echo "=== tipos de error (si los hay) ==="
grep -oE "Error.*" limit_err.log 2>/dev/null | sed 's/[0-9a-f]\{16,\}/<hash>/g' | sort | uniq -c | sort -rn | head
echo "=== drenaje ==="
for s in $(seq 1 40); do REM=$(have); echo "  t+$((s*5))s: sin_confirmar=$REM mempool=$(mp)"; [ "$REM" -eq 0 ] && break; sleep 5; done
