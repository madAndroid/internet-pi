#!/usr/bin/env bash

set -Eeu -o pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
start_log data-backup

DEBUG=${DEBUG:-}
if [ -n "$DEBUG" ]; then
    set -x
fi

BACKUP_BASE_DIR="/var/lib/backups"
NFS_MOUNT="/mnt/NFS/Backups/internet-machine/data-backup"
RESTIC_REPO="/var/lib/backups/data-backup-repo"
PROM_DATA="/var/lib/docker/volumes/internet-monitoring_prometheus_data"
NETALERTX_DATA="/var/lib/docker/volumes/internet-monitoring_netalertx_data"

NETALERTX_BACKUP_DIR="${BACKUP_BASE_DIR}/netalertx"
POSTGRESQL_BACKUP_DIR="${BACKUP_BASE_DIR}/postgresql"

TIMESTAMP=$(date +"%Y-%m-%d-%H-%M")

# Non-fatal problems collected along the way; any entry (or an abort) sends a
# Gotify notification from finish().
FAILURES=()
NETALERTX_STOPPED=false
PROMETHEUS_SNAPSHOT=""
FAILED_AT="unknown"
trap 'FAILED_AT="line ${LINENO}: ${BASH_COMMAND}"' ERR

finish() {
    local status=$?
    set +e
    # Always bring NetAlertX back, even if the backup step failed.
    if [ "${NETALERTX_STOPPED}" = true ]; then
        docker compose start netalertx || FAILURES+=("could not restart NetAlertX")
    fi
    # Remove the snapshot however the script exits, so stale ones never pin old blocks.
    if [ -n "${PROMETHEUS_SNAPSHOT}" ]; then
        rm -rf "${PROMETHEUS_SNAPSHOT}"
    fi
    if [ "${status}" -ne 0 ]; then
        FAILURES+=("aborted with exit ${status} at ${FAILED_AT}")
    fi
    if [ "${#FAILURES[@]}" -gt 0 ]; then
        echo "Backup problems:"
        printf '  - %s\n' "${FAILURES[@]}"
        notify_failure "Zimaboard data backup failed" \
            "$(printf -- '- %s\n' "${FAILURES[@]}")
Log: ${LOG}"
    fi
    echo -e "\nFinished backup at: $(date) (exit ${status})\n"
}
trap finish EXIT

echo -e "\n\nStarting backup at: $(date)\n"

mkdir -p ${BACKUP_BASE_DIR}/netalertx

cd /home/andrew/internet-monitoring

echo "Creating NetalertX backup..."
docker compose stop netalertx
NETALERTX_STOPPED=true
docker run --rm -v ${NETALERTX_DATA}/_data/config:/config \
    -v ${NETALERTX_DATA}/_data/db:/db \
    alpine tar -cz /config /db > ${NETALERTX_BACKUP_DIR}/netalertx-backup-${TIMESTAMP}.tar.gz.tmp
mv ${NETALERTX_BACKUP_DIR}/netalertx-backup-${TIMESTAMP}.tar.gz.tmp ${NETALERTX_BACKUP_DIR}/netalertx-backup-${TIMESTAMP}.tar.gz
docker compose start netalertx
NETALERTX_STOPPED=false

find ${BACKUP_BASE_DIR}/netalertx -mindepth 1 -mtime +7 -delete

# Create Prometheus Snapshot
echo "Creating Prometheus snapshot..."
SNAPSHOT_RESPONSE=$(curl -s -XPOST http://localhost:9090/api/v1/admin/tsdb/snapshot || true)

SNAPSHOT_NAME=$(echo "$SNAPSHOT_RESPONSE" | jq -r '.data.name' 2>/dev/null || true)

if [ -n "$SNAPSHOT_NAME" ] && [ "$SNAPSHOT_NAME" != "null" ]; then
    # Back the snapshot up in place: it is hard-linked into the TSDB, so it costs
    # almost nothing there, whereas copying ~50G into ${BACKUP_BASE_DIR} filled the disk.
    PROMETHEUS_SNAPSHOT="${PROM_DATA}/_data/snapshots/${SNAPSHOT_NAME}"
    echo "Snapshot created at: ${PROMETHEUS_SNAPSHOT}"
else
    echo "Failed to create Prometheus snapshot. Response: $SNAPSHOT_RESPONSE"
    FAILURES+=("Prometheus snapshot failed - Prometheus not backed up this run")
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
# shellcheck disable=SC2086  # PROMETHEUS_SNAPSHOT is deliberately dropped when empty
restic --password-file /etc/restic-password --repo ${RESTIC_REPO} \
    --verbose backup ${POSTGRESQL_BACKUP_DIR} ${NETALERTX_BACKUP_DIR} ${PROMETHEUS_SNAPSHOT}

echo
echo "Pruning old backups..."
# Grouped by host: the Prometheus snapshot path changes every run, so the default
# grouping (host + paths) would put each run in its own group and never prune.
restic --password-file /etc/restic-password --repo ${RESTIC_REPO} \
    --keep-hourly 12 --keep-daily 7 --keep-weekly 4 --keep-monthly 3 \
    --group-by host --verbose forget --prune

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
    echo "NFS root '${NFS_ROOT}' is not mounted, not syncing backup"
    FAILURES+=("NFS root ${NFS_ROOT} not mounted - backup not synced off-host")
fi
