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

### Bring Flux back only after nodes are schedulable again, so its
### controllers (and anything it reconciles) land on already-uncordoned
### nodes. Flux itself then restores every Longhorn-backed Deployment/
### StatefulSet the shutdown script scaled to zero, by re-applying its
### declared replica counts - no manual scale-up needed here.
echo "Scaling Flux controllers back up in flux-system:"
kubectl scale deployment --all -n flux-system --replicas=1

### The Kustomization's default 10m interval would otherwise leave
### everything Flux manages sitting at 0 replicas for up to that long -
### force an immediate reconcile instead.
echo "Forcing an immediate Flux reconciliation:"
NOW="$(date -u +%FT%TZ)"
kubectl annotate gitrepository flux-system -n flux-system --overwrite reconcile.fluxcd.io/requestedAt="$NOW"
kubectl annotate kustomization flux-system -n flux-system --overwrite reconcile.fluxcd.io/requestedAt="$NOW"

echo -e "\nStartup complete at: $(date)"
