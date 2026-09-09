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

# talosctl is mise-managed. mise's shell hook (`mise activate`) only runs in
# an interactive login shell via .zshrc/.bashrc, which a non-interactive
# invocation of this script (cron, ssh non-login session) never sources -
# so its shims dir is added to PATH directly here instead.
export PATH="${HOME}/.local/share/mise/shims:${PATH}"

# Pinned explicitly (matches terraform/.mise.toml's talos = "1.13.0") so the
# shim resolves even without a global default configured via
# `mise use -g talosctl@1.13.0` on the host running this script.
export MISE_TALOSCTL_VERSION="1.13.0"

if ! which talosctl >/dev/null 2>&1; then
	echo "talosctl not found in PATH - install it via mise before running this script"
	exit 1
fi

### UserKnownHostsFile=/dev/null tolerates rebuilt/renamed lab hosts with a
### stale known_hosts entry. LogLevel=ERROR suppresses the resulting "Warning:
### Permanently added..." noise, which would otherwise pollute parsed output.
SSH_OPTIONS="-o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

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

### Each Talos VM's libvirt domain name, keyed by its lab-kvm hypervisor
### (see terraform/as-dev/homelab/talos-cp.tf).
declare -A KVM_HOST_VMS=(
	[lab-kvm-01]="talos-cp-01 talos-wk-01"
	[lab-kvm-02]="talos-cp-02 talos-wk-02"
	[lab-kvm-03]="talos-cp-03 talos-wk-03"
)

POLL_INTERVAL=5
POLL_TIMEOUT=300

### VMs are autostart=true but don't always come up reliably on their own -
### confirm via virsh and start if needed, before trusting talosctl/kubectl.
ensure_kvm_vm_running() {
	local kvm_host="$1" vm="$2"
	local elapsed=0 output state

	while true; do
		# --connect qemu:///system: a bare `virsh` over a non-interactive ssh
		# command falls back to qemu:///session (no domains there).
		output=$(ssh $SSH_OPTIONS "$kvm_host" "virsh --connect qemu:///system domstate '$vm'" 2>&1)
		state=$(echo "$output" | tr -d '[:space:]')

		if [ "$state" == "running" ]; then
			echo "VM $vm on $kvm_host is running"
			return
		fi

		if [ "$elapsed" -ge "$POLL_TIMEOUT" ]; then
			echo "VM $vm on $kvm_host did not reach 'running' state within ${POLL_TIMEOUT}s (last output: '${output:-<no output - ssh unreachable>}') - aborting"
			exit 1
		fi

		if [ -n "$output" ]; then
			echo "VM $vm on $kvm_host reported: ${output} - attempting to start it"
			ssh $SSH_OPTIONS "$kvm_host" "virsh --connect qemu:///system start '$vm'" 2>&1 | sed "s/^/[$kvm_host] /"
		else
			echo "$kvm_host not yet reachable via ssh, retrying in ${POLL_INTERVAL}s..."
		fi

		sleep "$POLL_INTERVAL"
		elapsed=$((elapsed + POLL_INTERVAL))
	done
}

echo "Ensuring Talos VMs are running on their KVM hypervisors:"
for kvm_host in lab-kvm-0{1,2,3}; do
	for vm in ${KVM_HOST_VMS[$kvm_host]}; do
		ensure_kvm_vm_running "$kvm_host" "$vm"
	done
done

### Wait for apid to respond on each node - control planes first since etcd
### and the API server depend on them.
wait_for_talos_node() {
	local srv="$1" ip="$2"
	local elapsed=0
	until talosctl -n "$ip" version --short >/dev/null 2>&1; do
		if [ "$elapsed" -ge "$POLL_TIMEOUT" ]; then
			echo "Talos node $srv ($ip) did not come up within ${POLL_TIMEOUT}s - aborting"
			exit 1
		fi
		echo "$srv ($ip) not yet reachable via talosctl, retrying in ${POLL_INTERVAL}s..."
		sleep "$POLL_INTERVAL"
		elapsed=$((elapsed + POLL_INTERVAL))
	done
	echo "$srv ($ip) is up"
}

echo "Waiting for Talos control plane nodes to come up:"
for srv in "${!TALOS_CP_IPS[@]}"; do
	wait_for_talos_node "$srv" "${TALOS_CP_IPS[$srv]}"
done

echo "Waiting for Talos worker nodes to come up:"
for srv in "${!TALOS_WK_IPS[@]}"; do
	wait_for_talos_node "$srv" "${TALOS_WK_IPS[$srv]}"
done

### apid responding doesn't mean the API server is up yet - poll separately.
echo "Waiting for Kubernetes API to become reachable:"
elapsed=0
until kubectl get --raw='/healthz' >/dev/null 2>&1; do
	if [ "$elapsed" -ge "$POLL_TIMEOUT" ]; then
		echo "Kubernetes API did not become reachable within ${POLL_TIMEOUT}s - aborting"
		exit 1
	fi
	echo "API not yet reachable, retrying in ${POLL_INTERVAL}s..."
	sleep "$POLL_INTERVAL"
	elapsed=$((elapsed + POLL_INTERVAL))
done
echo "Kubernetes API is reachable"

### First uncordon all workers, then all control planes:
for srv in talos-wk-0{1,2,3}; do
	echo "Uncordoning worker: $srv"
	timeout $TIMEOUT kubectl uncordon $srv
done

for srv in talos-cp-0{1,2,3}; do
	echo "Uncordoning control plane: $srv"
	timeout $TIMEOUT kubectl uncordon $srv
done

### Flux restores every Longhorn-backed workload the shutdown script scaled
### to zero, by re-applying its declared replica counts.
echo "Scaling Flux controllers back up in flux-system:"
kubectl scale deployment --all -n flux-system --replicas=1

### Force a reconcile now rather than waiting on the 10m default interval.
echo "Forcing an immediate Flux reconciliation:"
NOW="$(date -u +%FT%TZ)"
kubectl annotate gitrepository flux-system -n flux-system --overwrite reconcile.fluxcd.io/requestedAt="$NOW"
kubectl annotate kustomization flux-system -n flux-system --overwrite reconcile.fluxcd.io/requestedAt="$NOW"

### Flux's Kustomization doesn't restore these on reconcile (its patches
### exclude .spec.replicas for them) - scale back up explicitly.
echo "Scaling smarthome deployments back up:"
for name in prowlarr radarr sonarr transmission; do
	kubectl scale deployment "$name" -n smarthome --replicas=1
done

echo -e "\nStartup complete at: $(date)"
