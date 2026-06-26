#!/bin/bash
set -e
cd /opt/leios/load
export PATH=/opt/leios/bin:$PATH
export CARDANO_NODE_NETWORK_ID=164
export CARDANO_NODE_SOCKET_PATH=/opt/leios/data/node.socket
ADDR=$(cat /opt/leios/keys/payment.addr)
SKEY=/opt/leios/keys/payment.skey
N=200

UTXO=$(cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json)
TXIN=$(echo "$UTXO" | jq -r 'to_entries|max_by(.value.value.lovelace)|.key')
echo "fan-out input=$TXIN -> $N salidas de 5 ADA"

OUTS=""
for i in $(seq 1 $N); do OUTS="$OUTS --tx-out ${ADDR}+5000000"; done
cardano-cli dijkstra transaction build --tx-in "$TXIN" $OUTS --change-address "$ADDR" --testnet-magic 164 --out-file split.raw
cardano-cli latest transaction sign --tx-body-file split.raw --signing-key-file "$SKEY" --testnet-magic 164 --out-file split.signed
SPLITID=$(cardano-cli latest transaction txid --tx-file split.signed | jq -r '.txhash // .' 2>/dev/null || cardano-cli latest transaction txid --tx-file split.signed)
echo "split TXID=$SPLITID"
cardano-cli latest transaction submit --tx-file split.signed --testnet-magic 164
echo "esperando confirmacion del fan-out..."
for i in $(seq 1 30); do
  CNT=$(cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json | jq '[to_entries[]|select(.value.value.lovelace==5000000)]|length')
  if [ "$CNT" -ge "$N" ]; then echo "CONFIRMADO: $CNT UTxOs de 5 ADA listos (intento $i)"; break; fi
  sleep 4
done
