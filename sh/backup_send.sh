#!/bin/bash
# Build a KillBot config backup and POST it to backups.killbot.ru.
set -euo pipefail

BACKUP_URL="https://backups.killbot.ru/send.php"
WORK_DIR=""

cleanup() {
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT

if ! command -v zip >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y zip >/dev/null
fi
if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required" >&2
    exit 1
fi

SERVER_IP=$(curl -s --connect-timeout 10 http://checkip.amazonaws.com | tr -d '[:space:]')
if [[ ! "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: failed to get SERVER_IP" >&2
    exit 1
fi

if ! command -v lsb_release >/dev/null 2>&1; then
    echo "ERROR: lsb_release is required" >&2
    exit 1
fi
VERSION=$(lsb_release -rs | tr -d '[:space:]')
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "ERROR: failed to get Ubuntu version" >&2
    exit 1
fi

if [[ ! -d /opt/killbot ]]; then
    echo "ERROR: /opt/killbot is missing; install KillBot first" >&2
    exit 1
fi

ARCHIVE_NAME="${SERVER_IP}_ubuntu${VERSION}.zip"
WORK_DIR=$(mktemp -d /tmp/kb-backup.XXXXXX)
ARCHIVE_PATH="${WORK_DIR}/${ARCHIVE_NAME}"

# Do not zip the whole /etc/letsencrypt tree. Fresh certbot on a new Ubuntu
# already ships options-ssl-*.conf / ssl-dhparams.pem / cli.ini for that
# package version; overwriting them from an older backup breaks nginx/apache
# includes and renew. live+archive+renewal+accounts+hooks is enough for
# existing certs to serve and for certbot renew to keep the same ACME account.
cd /
ZIP_ARGS=(-r -y -q "${ARCHIVE_PATH}")
ZIP_ARGS+=(opt/killbot)
[[ -d /etc/apache2/sites-enabled ]] && ZIP_ARGS+=(etc/apache2/sites-enabled)
[[ -d /etc/apache2/sites-available ]] && ZIP_ARGS+=(etc/apache2/sites-available)
[[ -d /etc/nginx/sites-enabled ]] && ZIP_ARGS+=(etc/nginx/sites-enabled)
[[ -d /etc/nginx/sites-available ]] && ZIP_ARGS+=(etc/nginx/sites-available)
for le_dir in live archive renewal accounts renewal-hooks; do
    if [[ -e "/etc/letsencrypt/${le_dir}" ]]; then
        ZIP_ARGS+=("etc/letsencrypt/${le_dir}")
    fi
done

echo "Creating ${ARCHIVE_NAME}..."
zip "${ZIP_ARGS[@]}"

if [[ ! -s "${ARCHIVE_PATH}" ]]; then
    echo "ERROR: backup zip is empty" >&2
    exit 1
fi

echo "Sending backup to ${BACKUP_URL}..."
HTTP_CODE=$(curl -sS --connect-timeout 20 --max-time 300 \
    -o "${WORK_DIR}/send.out" -w '%{http_code}' \
    -F "backup=@${ARCHIVE_PATH};type=application/zip" \
    "${BACKUP_URL}") || true

if [[ "${HTTP_CODE}" != "200" ]]; then
    echo "ERROR: backup upload failed (HTTP ${HTTP_CODE})" >&2
    cat "${WORK_DIR}/send.out" >&2 || true
    echo >&2
    exit 1
fi

echo "Backup sent: ${ARCHIVE_NAME} ($(stat -c%s "${ARCHIVE_PATH}") bytes)"
cat "${WORK_DIR}/send.out"
echo
