#!/usr/bin/env bash

set -Eeu -o pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
start_log file-backup

DEBUG=${DEBUG:-}
if [ -n "$DEBUG" ]; then
    set -x
fi

# Non-fatal problems collected along the way; any entry (or an abort) sends a
# Gotify notification from finish().
FAILURES=()
FAILED_AT="unknown"
trap 'FAILED_AT="line ${LINENO}: ${BASH_COMMAND}"' ERR

finish() {
    local status=$?
    set +e
    if [ "${status}" -ne 0 ]; then
        FAILURES+=("aborted with exit ${status} at ${FAILED_AT}")
    fi
    if [ "${#FAILURES[@]}" -gt 0 ]; then
        echo "Backup problems:"
        printf '  - %s\n' "${FAILURES[@]}"
        notify_failure "Zimaboard file backup failed" \
            "$(printf -- '- %s\n' "${FAILURES[@]}")
Log: ${LOG}"
    fi
    echo -e "\nFinished backup at: $(date) (exit ${status})\n"
}
trap finish EXIT

echo -e "\n\nStarting backup at: $(date)\n"

BACKUP_BASE_DIR="/var/lib/backups"
RESTIC_REPO="/var/lib/backups/file-backup-repo"
BACKUP_TARGETS="/var/lib/backups/etc/ /var/lib/backups/home/"
NFS_MOUNT="/mnt/NFS/Backups/internet-machine/file-backup"

for dir in etc home; do
    rsync -ar --delete /${dir}/ ${BACKUP_BASE_DIR}/${dir}/
done

restic --password-file /etc/restic-password --repo ${RESTIC_REPO} \
    --verbose backup ${BACKUP_TARGETS}

restic --password-file /etc/restic-password --repo ${RESTIC_REPO} \
    --keep-hourly 12 --keep-daily 7 --keep-weekly 4 --keep-monthly 3 \
    --verbose forget --prune

NFS_ROOT="/mnt/NFS/Backups"

# The share is autofs-mounted on demand: touch a path inside it first so the
# mountpoint check below sees it mounted (mountpoint -q alone doesn't trigger it).
ls "${NFS_ROOT}/" > /dev/null 2>&1 || true

if mountpoint -q "${NFS_ROOT}"; then
    mkdir -p "${NFS_MOUNT}"
    if touch "${NFS_MOUNT}/test"; then
        rm "${NFS_MOUNT}/test"
        echo "Syncing backups to NFS..."
        rsync -ar --delete --stats "${RESTIC_REPO}/" "${NFS_MOUNT}/"
        restic --password-file /etc/restic-password --repo "${RESTIC_REPO}" snapshots
    else
        echo "NFS mount point is not writable, exiting ..."
        exit 1
    fi
else
    echo "NFS root '${NFS_ROOT}' is not mounted, not syncing backups"
    FAILURES+=("NFS root ${NFS_ROOT} not mounted - backup not synced off-host")
fi
