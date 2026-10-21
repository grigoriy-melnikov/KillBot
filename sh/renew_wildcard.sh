#!/usr/bin/env bash
# renew_wildcard.sh
# Wildcard certificates are no longer issued or renewed by this script.

set -euo pipefail

require_kb_status() {
    if [[ "${KB_STATUS_CHECKED:-0}" == "1" ]]; then
        return 0
    fi
    local kb_bin=""
    if command -v kb >/dev/null 2>&1; then
        kb_bin="$(command -v kb)"
    elif [[ -x /usr/local/bin/kb ]]; then
        kb_bin="/usr/local/bin/kb"
    elif [[ -x /etc/init.d/kb ]]; then
        kb_bin="/etc/init.d/kb"
    else
        echo "ERROR: kb is not installed; aborting $(basename "$0")" >&2
        exit 1
    fi
    echo "Checking kb status..."
    if ! "$kb_bin" status; then
        echo "ERROR: kb status failed; aborting $(basename "$0")" >&2
        exit 1
    fi
    KB_STATUS_CHECKED=1
    export KB_STATUS_CHECKED
}

require_kb_status

echo "$(date '+%F %T') - Wildcard issue/renew via acme.sh is disabled; nothing to do"
exit 0
