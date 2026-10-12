#!/bin/bash
set -euo pipefail

DOMAIN="${1:-}"
KIND="${2:-access}"
MODE="${3:-cat}"

if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || [[ "$DOMAIN" == *..* ]]; then
    echo "Invalid domain" >&2
    exit 1
fi

case "$KIND" in
    access) FILE="/var/log/apache2/${DOMAIN}.access.log" ;;
    error) FILE="/var/log/apache2/${DOMAIN}.error.log" ;;
    *)
        echo "Invalid log type" >&2
        exit 1
        ;;
esac

if [ ! -f "$FILE" ]; then
    echo "Log file not found: $FILE" >&2
    exit 2
fi

if [ "$MODE" = "check" ]; then
    stat -c '%s' "$FILE"
    exit 0
fi

cat "$FILE"
