#!/usr/bin/env bash

LOG="${HOME}/log/startup.log"
TIMEOUT="300"

mkdir -p ~/log
[ -f ${LOG} ] || touch ${LOG}

echo "$(date)" >> ${LOG}
exec >> ${LOG}
exec 2>&1

echo -e "\nStartup starting at: $(date)\n"

### First drain all nodes, then all masters:
for srv in k8s-node-0{1,2,3,4,5}; do
	echo "Uncordoning node: $srv.int.stangl.co.za"
	timeout $TIMEOUT kubectl uncordon $srv.int.stangl.co.za
done

for srv in k8s-master-0{1,2,3,4,5}; do
	echo "Uncordoning master: $srv.int.stangl.co.za"
	timeout $TIMEOUT kubectl uncordon $srv.int.stangl.co.za
done

echo -e "\nStartup complete at: $(date)"
