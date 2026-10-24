#!/bin/bash
# Download the latest backup for this server and unpack it over current configs.
set -euo pipefail

BACKUP_URL="https://backups.killbot.ru/receive.php"
WORK_DIR=""

cleanup() {
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT

if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root (sudo)." >&2
    exit 1
fi

echo "Restore will update these folders from the backup:"
echo "  /opt/killbot"
echo "  /etc/letsencrypt (certificates: live, archive, renewal, accounts, renewal-hooks)"
echo "  /etc/apache2/sites-enabled"
echo "  /etc/apache2/sites-available"
echo "  /etc/nginx/sites-enabled"
echo "  /etc/nginx/sites-available"
echo
echo "Existing files with the same names will be replaced."
echo "Files that exist only on this server will stay."
echo
read -r -p "Restore data from the backup? Type yes to continue: " confirm
confirm=$(echo "${confirm}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
if [[ "${confirm}" != "yes" && "${confirm}" != "y" && "${confirm}" != "да" ]]; then
    echo "Cancelled."
    exit 0
fi

KB_BIN=""
if command -v kb >/dev/null 2>&1; then
    KB_BIN="$(command -v kb)"
elif [[ -x /usr/local/bin/kb ]]; then
    KB_BIN="/usr/local/bin/kb"
elif [[ -x /etc/init.d/kb ]]; then
    KB_BIN="/etc/init.d/kb"
else
    echo "ERROR: kb is not installed. Install KillBot on this server before restoring a backup." >&2
    exit 1
fi

echo "Checking kb status..."
if ! "${KB_BIN}" status; then
    echo "ERROR: kb status failed. Fix the current KillBot install before restoring." >&2
    exit 1
fi

if ! command -v unzip >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y unzip >/dev/null
fi
if ! command -v lsb_release >/dev/null 2>&1; then
    echo "ERROR: lsb_release is required" >&2
    exit 1
fi

LOCAL_VERSION=$(lsb_release -rs | tr -d '[:space:]')
WORK_DIR=$(mktemp -d /tmp/kb-restore.XXXXXX)
ARCHIVE_PATH="${WORK_DIR}/backup.zip"
HEADERS_PATH="${WORK_DIR}/headers.txt"

echo "Downloading backup..."
HTTP_CODE=$(curl -sS --connect-timeout 20 --max-time 300 \
    -D "${HEADERS_PATH}" -o "${ARCHIVE_PATH}" -w '%{http_code}' \
    "${BACKUP_URL}") || true

if [[ "${HTTP_CODE}" != "200" ]]; then
    echo "ERROR: backup download failed (HTTP ${HTTP_CODE})" >&2
    if [[ -s "${ARCHIVE_PATH}" ]]; then
        cat "${ARCHIVE_PATH}" >&2
        echo >&2
    fi
    exit 1
fi

if [[ ! -s "${ARCHIVE_PATH}" ]]; then
    echo "ERROR: downloaded backup is empty" >&2
    exit 1
fi

BACKUP_NAME=$(grep -i '^X-Backup-Filename:' "${HEADERS_PATH}" | head -1 | tr -d '\r' | sed 's/^[^:]*:[[:space:]]*//')
if [[ -z "${BACKUP_NAME}" ]]; then
    BACKUP_NAME=$(grep -i '^Content-Disposition:' "${HEADERS_PATH}" | head -1 | tr -d '\r' | sed -n 's/.*filename="\([^"]*\)".*/\1/p')
fi
if [[ -z "${BACKUP_NAME}" ]]; then
    echo "ERROR: backup server did not return a filename" >&2
    exit 1
fi

if [[ ! "${BACKUP_NAME}" =~ _ubuntu([0-9]+(\.[0-9]+)?) ]]; then
    echo "ERROR: cannot read Ubuntu version from backup name: ${BACKUP_NAME}" >&2
    exit 1
fi
BACKUP_VERSION="${BASH_REMATCH[1]}"

if [[ "${BACKUP_VERSION}" != "${LOCAL_VERSION}" ]]; then
    echo "ERROR: this backup is for another Ubuntu version." >&2
    echo "  Backup: Ubuntu ${BACKUP_VERSION} (${BACKUP_NAME})" >&2
    echo "  This server: Ubuntu ${LOCAL_VERSION}" >&2
    echo "Configs from another Ubuntu release may not work." >&2
    exit 1
fi

echo "Checking archive paths..."
while IFS= read -r name; do
    [[ -z "${name}" || "${name}" == */ ]] && continue
    if [[ "${name}" == *..* ]]; then
        echo "ERROR: backup archive contains illegal path: ${name}" >&2
        exit 1
    fi
    case "${name}" in
        opt/killbot/*|etc/letsencrypt/*|etc/apache2/sites-enabled/*|etc/apache2/sites-available/*|etc/nginx/sites-enabled/*|etc/nginx/sites-available/*)
            ;;
        *)
            echo "ERROR: backup archive contains unexpected path: ${name}" >&2
            exit 1
            ;;
    esac
done < <(unzip -Z -1 "${ARCHIVE_PATH}")

echo "Unpacking ${BACKUP_NAME} (Ubuntu ${BACKUP_VERSION})..."
unzip -o -q "${ARCHIVE_PATH}" -d /

if [[ -d /etc/letsencrypt ]]; then
    chmod 700 /etc/letsencrypt/accounts /etc/letsencrypt/archive /etc/letsencrypt/live 2>/dev/null || true
    find /etc/letsencrypt/archive -type f -name 'privkey*.pem' -exec chmod 600 {} \; 2>/dev/null || true
fi

echo "Restore finished."
echo "Reload services: kb reload"
echo "Then check: kb status"
