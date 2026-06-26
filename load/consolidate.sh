#!/bin/bash
# Junta todos los UTxOs en pocos grandes (tx de <=200 inputs -> 1 output via change)
cd /opt/leios/load
export PATH=/opt/leios/bin:$PATH
export CARDANO_NODE_NETWORK_ID=164
export CARDANO_NODE_SOCKET_PATH=/opt/leios/data/node.socket
ADDR=$(cat /opt/leios/keys/payment.addr); SKEY=/opt/leios/keys/payment.skey
cnt(){ cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json | jq 'length'; }
echo "[consolidate] inicio: $(cnt) UTxOs"
while [ "$(cnt)" -gt 5 ]; do
  C=$(cnt)
  INS=$(cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json | jq -r 'keys[]' | head -200)
  TXIN=""; for u in $INS; do TXIN="$TXIN --tx-in $u"; done
  cardano-cli dijkstra transaction build $TXIN --change-address "$ADDR" --testnet-magic 164 --out-file con.raw >/dev/null 2>&1 || { echo "[consolidate] build fallo, reintento"; sleep 5; continue; }
  cardano-cli latest transaction sign --tx-body-file con.raw --signing-key-file "$SKEY" --testnet-magic 164 --out-file con.signed
  cardano-cli latest transaction submit --tx-file con.signed --testnet-magic 164 >/dev/null 2>&1
  for k in $(seq 1 50); do [ "$(cnt)" -lt "$C" ] && break; sleep 3; done
  echo "[consolidate] $C -> $(cnt)"
done
echo "[consolidate] final: $(cnt) UTxOs"
cardano-cli latest query utxo --address "$ADDR" --testnet-magic 164 --output-json | jq -r "[.[].value.lovelace]|{utxos:length, total_ADA:(add/1000000), max_ADA:(max/1000000)}"
