#!/usr/bin/env bash
#
set -x

LOG="${HOME}/log/shutdown.log"
TIMEOUT="120"

mkdir -p ~/log
[ -f ${LOG} ] || touch ${LOG}

echo "$(date)" >> ${LOG}
exec >> ${LOG}
exec 2>&1

# talosctl is mise-managed. mise's shell hook (`mise activate`) only runs in
# an interactive login shell via .zshrc/.bashrc, which a non-interactive
# invocation of this script (cron, ssh non-login session) never sources -
# so its shims dir is added to PATH directly here instead.
export PATH="${HOME}/.local/share/mise/shims:${PATH}"

if ! which talosctl >/dev/null 2>&1; then
	echo "talosctl not found in PATH - install it via mise before running this script"
	exit 1
fi

SSH_OPTIONS="-o ConnectTimeout=3 -o StrictHostKeyChecking=no"

echo -e "\nShutdown starting at: $(date)\n"

### Talos control-plane and worker nodes (kubectl sees them by their short
### hostname - set via HostnameConfig with no domain suffix - while
### talosctl talks to each node's static IP directly, since that's what's
### in the apid certificate's SAN list, not the FQDN).
declare -A TALOS_CP_IPS=(
	[talos-cp-01]="192.168.88.121"
	[talos-cp-02]="192.168.88.122"
	[talos-cp-03]="192.168.88.123"
)
declare -A TALOS_WK_IPS=(
	[talos-wk-01]="192.168.88.131"
	[talos-wk-02]="192.168.88.132"
	[talos-wk-03]="192.168.88.133"
)

### First drain all workers, then all control planes:
for srv in "${!TALOS_WK_IPS[@]}"; do
	echo "Cordoning worker: $srv"
	kubectl cordon $srv
done

for srv in "${!TALOS_CP_IPS[@]}"; do
	echo "Cordoning control plane: $srv"
	kubectl cordon $srv
done

for srv in "${!TALOS_WK_IPS[@]}"; do
	echo "Draining worker: $srv"
	kubectl drain $srv --timeout=${TIMEOUT}s --ignore-daemonsets --delete-emptydir-data
done

for srv in "${!TALOS_CP_IPS[@]}"; do
	echo "Draining control plane: $srv"
	kubectl drain $srv --timeout=${TIMEOUT}s --ignore-daemonsets --delete-emptydir-data
done

echo "Shutting down Talos control plane nodes:"
for srv in "${!TALOS_CP_IPS[@]}"; do echo $srv; talosctl shutdown -n "${TALOS_CP_IPS[$srv]}"; sleep 3; done
echo "Shutting down Talos worker nodes:"
for srv in "${!TALOS_WK_IPS[@]}"; do echo $srv; talosctl shutdown -n "${TALOS_WK_IPS[$srv]}"; sleep 3; done

echo "Shutting down KVM hypervisors:"
for srv in lab-kvm-0{1,2,3,4}; do echo $srv; ssh $SSH_OPTIONS $srv "sudo shutdown -h now"; sleep 3; done

echo "Shutting down Network attached storage machines:"
for nas in nas-storage; do echo $nas; ssh $SSH_OPTIONS admin@$nas "sudo poweroff"; sleep 3; done
#echo "STORAGE NAS SHUTDOWN DISABLED"

if [ "$1" == "ALL" ]; then
    echo "Shutting down linux desktop machine:"
    for srv in desktop; do echo $srv; ssh $SSH_OPTIONS $srv "sudo shutdown -h now"; sleep 3; done
    ## Mac mini will shut off with Lounge Plug
    for srv in macmini; do echo $srv; ssh $SSH_OPTIONS $srv "sudo shutdown -h now"; sleep 3; done
    #echo "Shutting down media NAS machine:"
    #for nas in nas-media; do echo $nas; ssh $SSH_OPTIONS admin@$nas "sudo poweroff"; sleep 3; done
fi

echo -e "\nShutdown complete at: $(date)\n"
