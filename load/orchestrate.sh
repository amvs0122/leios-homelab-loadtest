#!/bin/bash
cd /opt/leios/load
echo "######## ORQUESTADOR INICIO $(date -u +%H:%M:%S) ########"
echo "######## PASO 1: CONSOLIDAR ########"
bash /opt/leios/consolidate.sh
echo "######## PASO 2: SOSTENIDO (10 tx/s x 150s) ########"
bash /opt/leios/load_sustained.sh 10 150
echo "######## PASO 3: CONSOLIDAR ########"
bash /opt/leios/consolidate.sh
echo "######## PASO 4: LIMITE (2000 tx, par 80) ########"
bash /opt/leios/load_limit.sh 2000 80
echo "######## ORQUESTADOR FIN $(date -u +%H:%M:%S) ########"
