#!/usr/bin/env bash

LOG="${HOME}/log/startup.log"
TIMEOUT="300"

mkdir -p ~/log
[ -f ${LOG} ] || touch ${LOG}

# Tee'd rather than plain-redirected so the script is still useful run
# interactively (console output) as well as from cron (log file only).
exec > >(tee -a "${LOG}") 2>&1

echo "$(date)"

echo -e "\nStartup starting at: $(date)\n"

### First uncordon all workers, then all control planes:
for srv in talos-wk-0{1,2,3}; do
	echo "Uncordoning worker: $srv"
	timeout $TIMEOUT kubectl uncordon $srv
done

for srv in talos-cp-0{1,2,3}; do
	echo "Uncordoning control plane: $srv"
	timeout $TIMEOUT kubectl uncordon $srv
done

echo -e "\nStartup complete at: $(date)"
