#!/usr/bin/env bash

TARGETS="$@"

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
start_log lab-shutdown

echo "Starting shutdown for: ${TARGETS} at: $(date)"

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
