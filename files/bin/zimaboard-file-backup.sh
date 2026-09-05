#!/usr/bin/env bash

set -eu -o pipefail

DEBUG=${DEBUG:-}
if [ -n "$DEBUG" ]; then
    set -x
fi

echo -e "\n\nStarting backup at: $(date)\n"

BACKUP_BASE_DIR="/var/lib/backups"
RESTIC_REPO="/var/lib/backups/file-backup-repo"
BACKUP_TARGETS="/var/lib/backups/etc/ /var/lib/backups/home/"
NFS_MOUNT="/mnt/NFS/Backups/internet-machine/file-backup"

TIMESTAMP=$(date +"%Y-%m-%d-%H-%M")

for dir in etc home; do
    rsync -ar --delete /${dir}/ ${BACKUP_BASE_DIR}/${dir}/
done

restic --password-file /etc/restic-password --repo ${RESTIC_REPO} \
    --verbose backup ${BACKUP_TARGETS}

restic --password-file /etc/restic-password --repo ${RESTIC_REPO} \
    --keep-hourly 12 --keep-daily 7 --keep-weekly 4 --keep-monthly 3 \
    --verbose forget --prune

mkdir -p ${NFS_MOUNT}

NFS_ROOT="/mnt/NFS/Backups"

if mountpoint -q "${NFS_ROOT}"; then
    mkdir -p "${NFS_MOUNT}"
    touch "${NFS_MOUNT}/test"
    if [ $? == 0 ]; then
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
fi

echo -e "\nFinished backup at: $(date)\n"
