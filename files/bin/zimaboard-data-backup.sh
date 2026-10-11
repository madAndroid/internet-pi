#!/usr/bin/env bash

set -eu -o pipefail

# Log alongside the startup/shutdown scripts in ~/log. This runs as root from
# cron, so resolve the directory from the script's location (~/bin/../log)
# rather than ${HOME}.
LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/log"
LOG="${LOG_DIR}/data-backup.log"
mkdir -p "${LOG_DIR}"
[ -f "${LOG}" ] || touch "${LOG}"

# Tee'd rather than plain-redirected so the script is still useful run
# interactively (console output) as well as from cron (log file only).
exec > >(tee -a "${LOG}") 2>&1

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
POSTGRESQL_BACKUP_DIR="${BACKUP_BASE_DIR}/postgresql"

TIMESTAMP=$(date +"%Y-%m-%d-%H-%M")

mkdir -p ${BACKUP_BASE_DIR}/netalertx

cd /home/andrew/internet-monitoring

echo "Creating NetalertX backup..."
docker compose stop netalertx
# Always bring NetAlertX back, even if the backup step fails (set -e).
trap 'docker compose start netalertx' EXIT
docker run --rm -v ${NETALERTX_DATA}/_data/config:/config \
    -v ${NETALERTX_DATA}/_data/db:/db \
    alpine tar -cz /config /db > ${NETALERTX_BACKUP_DIR}/netalertx-backup-${TIMESTAMP}.tar.gz.tmp
mv ${NETALERTX_BACKUP_DIR}/netalertx-backup-${TIMESTAMP}.tar.gz.tmp ${NETALERTX_BACKUP_DIR}/netalertx-backup-${TIMESTAMP}.tar.gz
docker compose start netalertx
trap - EXIT

find ${BACKUP_BASE_DIR}/netalertx -mindepth 1 -mtime +7 -delete

# Create Prometheus Snapshot
echo "Creating Prometheus snapshot..."
SNAPSHOT_RESPONSE=$(curl -s -XPOST http://localhost:9090/api/v1/admin/tsdb/snapshot)

SNAPSHOT_NAME=$(echo $SNAPSHOT_RESPONSE | jq -r '.data.name')

PROMETHEUS_SNAPSHOT=""
if [ -n "$SNAPSHOT_NAME" ] && [ "$SNAPSHOT_NAME" != "null" ]; then
    # Back the snapshot up in place: it is hard-linked into the TSDB, so it costs
    # almost nothing there, whereas copying ~50G into ${BACKUP_BASE_DIR} filled the disk.
    PROMETHEUS_SNAPSHOT="${PROM_DATA}/_data/snapshots/${SNAPSHOT_NAME}"
    echo "Snapshot created at: ${PROMETHEUS_SNAPSHOT}"
    # Remove the snapshot however the script exits, so stale ones never pin old blocks.
    trap 'rm -rf "${PROMETHEUS_SNAPSHOT}"' EXIT
else
    echo "Failed to create Prometheus snapshot. Response: $SNAPSHOT_RESPONSE"
fi

echo
echo "Creating PostgreSQL backups (consolidated 'postgres' container)..."
mkdir -p "${POSTGRESQL_BACKUP_DIR}"
# Dump every application database on the instance, so newly added apps are covered automatically.
DATABASES=$(docker exec postgres psql -U postgres -d postgres -Atc \
    "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY datname")
if [ -z "${DATABASES}" ]; then
    echo "No PostgreSQL databases found - refusing to continue"
    exit 1
fi
for db in ${DATABASES}; do
    echo "  dumping ${db}..."
    docker exec postgres pg_dump -U postgres "${db}" > "${POSTGRESQL_BACKUP_DIR}/${db}-${TIMESTAMP}.sql.tmp"
    mv "${POSTGRESQL_BACKUP_DIR}/${db}-${TIMESTAMP}.sql.tmp" "${POSTGRESQL_BACKUP_DIR}/${db}-${TIMESTAMP}.sql"
done
find ${POSTGRESQL_BACKUP_DIR} -ctime +7 -type f -delete

echo
echo "Backing up with Restic"
restic --password-file /etc/restic-password --repo ${RESTIC_REPO} \
    --verbose backup ${POSTGRESQL_BACKUP_DIR} ${NETALERTX_BACKUP_DIR} ${PROMETHEUS_SNAPSHOT}

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
