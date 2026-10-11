# shellcheck shell=bash
# Shared helpers for the scripts in ~/bin. Source it; don't run it.

# ~/logs, resolved from this file's location (~/bin/lib/../..) so it is the same
# when a script runs as root from cron, where ${HOME} is /root.
LOG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)/logs"

# start_log <name>: send this run's output to a new timestamped file in
# ${LOG_DIR}. Tee'd rather than plain-redirected so the script is still useful
# run interactively (console output) as well as from cron (log file only).
# Files older than the retention period are pruned by a daily cron job.
start_log() {
    mkdir -p "${LOG_DIR}"
    LOG="${LOG_DIR}/$1-$(date +%Y-%m-%dT%H-%M-%S).log"
    exec > >(tee -a "${LOG}") 2>&1
}

GOTIFY_URL="${GOTIFY_URL:-http://127.0.0.1:8088}"
GOTIFY_TOKEN_FILE="${GOTIFY_TOKEN_FILE:-/etc/gotify-backup-token}"

# notify_failure <title> <message>: push a high-priority Gotify message.
# Best effort - it never fails the caller, it only logs when it can't send.
notify_failure() {
    local title="$1" message="$2"
    if [ ! -r "${GOTIFY_TOKEN_FILE}" ]; then
        echo "WARNING: cannot read ${GOTIFY_TOKEN_FILE}; Gotify notification not sent"
        return 0
    fi
    # Header read from stdin so the token never shows up in the process list;
    # --form-string so a message starting with @ or < isn't read as a file.
    if printf 'X-Gotify-Key: %s\n' "$(cat "${GOTIFY_TOKEN_FILE}")" |
        curl -sS -f -m 10 -o /dev/null -H @- \
            --form-string "title=${title}" \
            --form-string "message=${message}" \
            --form-string "priority=8" \
            "${GOTIFY_URL}/message"; then
        echo "Sent Gotify failure notification"
    else
        echo "WARNING: failed to send Gotify notification"
    fi
}
