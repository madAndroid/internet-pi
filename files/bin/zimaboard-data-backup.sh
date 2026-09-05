#!/usr/bin/env bash

set -eu -o pipefail

DEBUG=${DEBUG:-}
if [ -n "$DEBUG" ]; then
    set -x
fi

echo -e "\n\nStarting backup at: $(date)\n"

BACKUP_BASE_DIR="/var/lib/backups"
NFS_MOUNT="/mnt/NFS/Backups/internet-machine/data-backup"
RESTIC_REPO="/var/lib/backups/data-backup-repo"
PROM_DATA="/var/lib/docker/volumes/internet-monitoring_prometheus_data"
NETALERTX_DATA="/var/lib/docker/volumes/internet-monitoring_netalertx_data"

NETALERTX_BACKUP_DIR="${BACKUP_BASE_DIR}/netalertx"
PROMETHEUS_BACKUP_DIR="${BACKUP_BASE_DIR}/prometheus"
POSTGRESQL_BACKUP_DIR="${BACKUP_BASE_DIR}/postgresql"

TIMESTAMP=$(date +"%Y-%m-%d-%H-%M")

mkdir -p ${BACKUP_BASE_DIR}/netalertx

cd /home/andrew/internet-monitoring

echo "Creating NetalertX backup..."
docker compose stop netalertx
docker run --rm -v ${NETALERTX_DATA}/_data/config:/config \
    -v ${NETALERTX_DATA}/_data/db:/db \
    alpine tar -cz /config /db > ${NETALERTX_BACKUP_DIR}/netalertx-backup-${TIMESTAMP}.tar.gz
docker compose start netalertx

find ${BACKUP_BASE_DIR}/netalertx -mindepth 1 -mtime +7 -delete

# Create Prometheus Snapshot
echo "Creating Prometheus snapshot..."
SNAPSHOT_RESPONSE=$(curl -s -XPOST http://localhost:9090/api/v1/admin/tsdb/snapshot)

SNAPSHOT_NAME=$(echo $SNAPSHOT_RESPONSE | jq -r '.data.name')

if [ -n "$SNAPSHOT_NAME" ] && [ "$SNAPSHOT_NAME" != "null" ]; then
    SNAPSHOT_SOURCE="${PROM_DATA}/_data/snapshots/${SNAPSHOT_NAME}"
    mkdir -p "${PROMETHEUS_BACKUP_DIR}"

    echo "Snapshot created at: ${SNAPSHOT_SOURCE}"

    # Move the snapshot logic to the backup directory
    TARGET_DIR="${PROMETHEUS_BACKUP_DIR}/prometheus-snapshot-${TIMESTAMP}"
    echo "Moving snapshot to: ${TARGET_DIR}"
    mv "${SNAPSHOT_SOURCE}" "${TARGET_DIR}"

    # Clean up old snapshot directories (keep top 1 most recent locally)
    find "${PROMETHEUS_BACKUP_DIR}" -mindepth 1 -maxdepth 1 -name "prometheus-snapshot-*" -type d -printf '%T@\t%p\n' | \
        sort -rn | tail -n +2 | cut -f2- | xargs -r rm -rf
else
    echo "Failed to create Prometheus snapshot. Response: $SNAPSHOT_RESPONSE"
fi

echo
echo "Creating Grafana Postgres backup..."
su - postgres -c "pg_dump grafana" > ${POSTGRESQL_BACKUP_DIR}/grafana-${TIMESTAMP}.sql
find ${POSTGRESQL_BACKUP_DIR} -ctime +7 -type f -delete

echo
echo "Backing up with Restic"
restic --password-file /etc/restic-password --repo ${RESTIC_REPO} \
    --verbose backup ${POSTGRESQL_BACKUP_DIR} ${NETALERTX_BACKUP_DIR} ${PROMETHEUS_BACKUP_DIR}

echo
echo "Pruning old backups..."
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
    echo "NFS root '${NFS_ROOT}' is not mounted, not syncing backup"
fi

echo -e "\nFinished backup at: $(date)\n"
