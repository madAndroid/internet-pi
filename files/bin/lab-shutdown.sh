#!/usr/bin/env bash

TARGETS="$@"

LOG="${HOME}/log/shutdown.log"

echo "Starting shutdown for: ${TARGETS} at: $(date)"

mkdir -p ~/log
[ -f ${LOG} ] || touch ${LOG}

echo "$(date)" >> ${LOG}
exec >> ${LOG}
exec 2>&1

SHUTDOWN_CMD="sudo shutdown -h now"


for TARGET in ${TARGETS}; do
    echo "Shutting down ${TARGET}:"
    if ([ "${TARGET}" == "nas-storage" ] || [ "${TARGET}" == "nas-media" ]); then
        SHUTDOWN_CMD="sudo poweroff"
    fi
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ${TARGET} ${SHUTDOWN_CMD}
    sleep 3
done

echo "Shutdown for: ${TARGETS} complete at: $(date)"
