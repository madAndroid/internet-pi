#!/usr/bin/env bash

LOG="${HOME}/log/shutdown.log"
TIMEOUT="10"

mkdir -p ~/log
[ -f ${LOG} ] || touch ${LOG}

# Tee'd rather than plain-redirected so the script is still useful run
# interactively (console output) as well as from cron (log file only).
exec > >(tee -a "${LOG}") 2>&1

echo "$(date)"

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
### stale known_hosts entry (StrictHostKeyChecking=no alone still rejects a
### *changed* key). LogLevel=ERROR suppresses the resulting "Warning:
### Permanently added..." noise.
SSH_OPTIONS="-o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

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

### Cordon all workers, then all control planes:
for srv in "${!TALOS_WK_IPS[@]}"; do
	echo "Cordoning worker: $srv"
	kubectl cordon $srv
done

for srv in "${!TALOS_CP_IPS[@]}"; do
	echo "Cordoning control plane: $srv"
	kubectl cordon $srv
done

### Stop Flux first, or it'll restore replica counts out from under us mid-drain.
echo "Scaling down Flux controllers in flux-system:"
kubectl scale deployment --all -n flux-system --replicas=0

### No `kubectl drain` here - every node is going down together, so there's
### no PDB/service-availability concern to respect. The one thing that still
### matters is giving Longhorn-backed workloads a clean release of their
### volumes before power-off, so scale them to 0 and wait for the pods to
### actually terminate.
scale_down_and_wait() {
	local kind="$1" ns="$2" name="$3"
	echo "Scaling down ${kind}/${name} in ${ns} (Longhorn-backed)"
	kubectl scale "$kind" "$name" -n "$ns" --replicas=0

	local selector
	selector=$(kubectl get "$kind" "$name" -n "$ns" -o json |
		jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')
	if [ -n "$selector" ]; then
		kubectl wait --for=delete pod -n "$ns" -l "$selector" --timeout=${TIMEOUT}s ||
			echo "Warning: pods for ${kind}/${name} in ${ns} did not terminate within ${TIMEOUT}s"
	fi
}

echo "Identifying Longhorn storage classes:"
LONGHORN_SCS=$(kubectl get storageclass -o json |
	jq -c '[.items[] | select(.provisioner=="driver.longhorn.io") | .metadata.name]')

echo "Scaling down StatefulSets using Longhorn storage:"
kubectl get statefulset -A -o json | jq -r --argjson scs "$LONGHORN_SCS" '
	.items[]
	| select(any(.spec.volumeClaimTemplates[]?.spec.storageClassName; . as $sc | $scs | index($sc)))
	| "\(.metadata.namespace) \(.metadata.name)"
' | while read -r ns name; do
	[ -n "$name" ] && scale_down_and_wait statefulset "$ns" "$name"
done

echo "Identifying PVCs backed by Longhorn storage:"
LONGHORN_PVCS=$(kubectl get pvc -A -o json | jq -c --argjson scs "$LONGHORN_SCS" '
	[.items[] | select(.spec.storageClassName as $sc | $scs | index($sc)) | "\(.metadata.namespace)/\(.metadata.name)"]
')

echo "Scaling down Deployments using Longhorn storage:"
kubectl get deployment -A -o json | jq -r --argjson pvcs "$LONGHORN_PVCS" '
	.items[] as $dep
	| $dep.metadata.namespace as $ns
	| select(any($dep.spec.template.spec.volumes[]?.persistentVolumeClaim.claimName; . as $c | $pvcs | index("\($ns)/\($c)")))
	| "\($ns) \($dep.metadata.name)"
' | while read -r ns name; do
	[ -n "$name" ] && scale_down_and_wait deployment "$ns" "$name"
done

### talosctl shutdown watches for a "shutdown confirmed" event, but once the
### node actually powers off its apid connection just drops - the client
### doesn't reliably see that event before the connection dies, and instead
### loops "unavailable, retrying..." forever. timeout keeps that from
### hanging the whole batch; the shutdown itself has already been issued by
### the time it fires.
echo "Shutting down Talos nodes:"
for srv in "${!TALOS_CP_IPS[@]}"; do
	echo "$srv"
	timeout "${TIMEOUT}" talosctl shutdown -n "${TALOS_CP_IPS[$srv]}" &
done
for srv in "${!TALOS_WK_IPS[@]}"; do
	echo "$srv"
	timeout "${TIMEOUT}" talosctl shutdown -n "${TALOS_WK_IPS[$srv]}" &
done
wait

# talosctl shutdown returning only means the request was accepted, not that
# the guest has actually finished halting - a KVM host powering off before
# that happens is equivalent to yanking power from its VMs. Give Talos a
# moment to actually stop containerd/etcd and unmount before we cut power to
# the hypervisors running them.
sleep 10

echo "Shutting down KVM hypervisors:"
for srv in lab-kvm-0{1,2,3}; do
	echo "$srv"
	timeout "${TIMEOUT}" ssh $SSH_OPTIONS $srv "sudo shutdown -h now" &
done
wait

echo "Shutting down Network attached storage machines:"
for nas in nas-storage; do
	echo "$nas"
	timeout "${TIMEOUT}" ssh $SSH_OPTIONS admin@$nas "sudo poweroff" &
done
wait
#echo "STORAGE NAS SHUTDOWN DISABLED"

if [ "$1" == "ALL" ]; then
    echo "Shutting down linux desktop machine:"
    timeout "${TIMEOUT}" ssh $SSH_OPTIONS desktop "sudo shutdown -h now" &
    ## Mac mini will shut off with Lounge Plug
    timeout "${TIMEOUT}" ssh $SSH_OPTIONS macmini "sudo shutdown -h now" &
    wait
    #echo "Shutting down media NAS machine:"
    #for nas in nas-media; do echo $nas; ssh $SSH_OPTIONS admin@$nas "sudo poweroff"; sleep 3; done
fi

echo -e "\nShutdown complete at: $(date)\n"
