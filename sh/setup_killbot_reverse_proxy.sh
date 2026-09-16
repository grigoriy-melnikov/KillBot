#!/bin/bash
#
# Reverse proxy for the site.
#
# Usage: sudo bash setup_killbot_reverse_proxy.sh [-y] SITE_DOMAIN
#
#   -y  skip the "Enter..." pause after instructions (unattended)
#
# /opt/killbot/killbot_revers                        — shared Killbot backends (one domain per line)
# /opt/killbot/settings/SITE/killbot_revers          — r1.SITE:backend, r2.SITE:backend, … (full format immediately)
# Nginx reverse proxy — only with a wildcard in /opt/killbot/ssl/SITE_DOMAIN/ (fullchain.pem + privkey.pem).
# Nginx configs: /etc/nginx/sites-available/000-{proxy_fqdn}.conf (000- prefix — loaded before *.SITE)
#
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _dns_hint in "${_SCRIPT_DIR}/dns_provider_hint.sh" "/opt/killbot/dns_provider_hint.sh"; do
    if [[ -f "${_dns_hint}" ]]; then
        # shellcheck source=dns_provider_hint.sh disable=SC1091
        source "${_dns_hint}"
        break
    fi
done
unset _dns_hint

BACKEND_SERVERS=(
    "https://10052024.ru"
    "https://r1.kill-bot.ru"
    "https://data.killbot.ru"
    "https://r3.nl.kill-bot.ru"
    "https://r4.us.kill-bot.ru"
    "https://r6.sg.kill-bot.net"
)

# Check proxy A records only via a public resolver (Google DNS by default)
DNSServer="${DNSServer:-8.8.8.8}"
NGINX_SITES_AVAILABLE="${NGINX_SITES_AVAILABLE:-/etc/nginx/sites-available}"
NGINX_SITES_ENABLED="${NGINX_SITES_ENABLED:-/etc/nginx/sites-enabled}"
REVERSE_PROXY_CONF_PREFIX="${REVERSE_PROXY_CONF_PREFIX:-000-}"
GLOBAL_BACKENDS_FILE="${GLOBAL_BACKENDS_FILE:-/opt/killbot/killbot_revers}"
SETTINGS_BASE="${SETTINGS_BASE:-/opt/killbot/settings}"
PROXY_LABEL_PREFIX="${PROXY_LABEL_PREFIX:-r}"
KEEP_EXISTING_MAP="${KEEP_EXISTING_MAP:-1}"
AUTO_YES=0

usage() {
    echo "Usage: sudo bash $0 [-y] SITE_DOMAIN"
    echo "  -y  skip the "Enter..." pause after instructions (unattended)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            AUTO_YES=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "ERROR: unknown parameter: $1"
            usage
            ;;
        *)
            if [[ -n "${SITE_DOMAIN:-}" ]]; then
                echo "ERROR: extra argument: $1"
                usage
            fi
            SITE_DOMAIN="${1,,}"
            SITE_DOMAIN="${SITE_DOMAIN#https://}"
            SITE_DOMAIN="${SITE_DOMAIN#http://}"
            SITE_DOMAIN="${SITE_DOMAIN%%/*}"
            SITE_DOMAIN="${SITE_DOMAIN#www.}"
            shift
            ;;
    esac
done

[[ -n "${SITE_DOMAIN:-}" ]] || usage

if [[ ! "$SITE_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    echo "ERROR: invalid domain: ${SITE_DOMAIN}"
    exit 1
fi

SITE_DIR="${SETTINGS_BASE}/${SITE_DOMAIN}"
SITE_REVERS="${SITE_DIR}/killbot_revers"
SSL_KILLBOT_DIR="/opt/killbot/ssl/${SITE_DOMAIN}"
SSL_CERT="${SSL_KILLBOT_DIR}/fullchain.pem"
SSL_KEY="${SSL_KILLBOT_DIR}/privkey.pem"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Run as root: sudo $0 SITE_DOMAIN"
    exit 1
fi

for cmd in dig curl openssl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required"; exit 1; }
done

site_killbot_ssl_cert_ok() {
    [[ -f "${SSL_CERT}" && -f "${SSL_KEY}" ]]
}

site_killbot_ssl_wildcard_ok() {
    site_killbot_ssl_cert_ok && is_wildcard_cert "${SSL_CERT}" "${SITE_DOMAIN}"
}

killbot_ssl_fail_reason() {
    if ! site_killbot_ssl_cert_ok; then
        echo "certificate not found in ${SSL_KILLBOT_DIR}/ (need fullchain.pem and privkey.pem)"
        return 0
    fi
    echo "certificate found, but it is not a wildcard (*.${SITE_DOMAIN})"
}

fail_wildcard_cert_required() {
    local reason="$1"
    echo "ERROR: proxy subdomains require a wildcard certificate (*.${SITE_DOMAIN})." >&2
    echo "       Place fullchain.pem and privkey.pem in the directory:" >&2
    echo "       ${SSL_KILLBOT_DIR}/" >&2
    if [[ -n "$reason" ]]; then
        echo "       ${reason}" >&2
    fi
}

remove_reverse_proxy_nginx_configs() {
    local quiet="${1:-0}"
    [[ -s "${SITE_REVERS}" ]] || return 0

    local proxy conf_name conf_path removed=0

    for proxy in "${SITE_PROXIES[@]}"; do
        [[ -n "$proxy" ]] || continue
        conf_name="${REVERSE_PROXY_CONF_PREFIX}${proxy}.conf"
        conf_path="${NGINX_SITES_AVAILABLE}/${conf_name}"

        if [[ -f "${conf_path}" ]]; then
            rm -f "${conf_path}"
            [[ "$quiet" == "1" ]] || echo "Removed nginx config: ${conf_path}"
            removed=1
        fi
        if [[ -f "${NGINX_SITES_ENABLED}/${conf_name}" || -L "${NGINX_SITES_ENABLED}/${conf_name}" ]]; then
            rm -f "${NGINX_SITES_ENABLED}/${conf_name}"
            [[ "$quiet" == "1" ]] || echo "Removed nginx enabled: ${NGINX_SITES_ENABLED}/${conf_name}"
            removed=1
        fi
    done

    if [[ "$removed" -eq 1 ]] && command -v nginx >/dev/null 2>&1; then
        reload_nginx
    fi
}

ensure_killbot_wildcard_ssl_or_abort() {
    local reason=""

    if site_killbot_ssl_wildcard_ok; then
        return 0
    fi

    reason="$(killbot_ssl_fail_reason)"
    remove_reverse_proxy_nginx_configs
    fail_wildcard_cert_required "$reason"
    exit 1
}

# SAN *.domain in fullchain.pem (same as renew_wildcard.sh / kb install)
is_wildcard_cert() {
    local certfile="$1"
    local domain="$2"
    local n
    if [[ ! -f "$certfile" ]]; then
        return 1
    fi
    mapfile -t dns_entries < <(openssl x509 -in "$certfile" -noout -text 2>/dev/null | grep -oP 'DNS:[^,]+' | sed 's/^DNS://' || true)
    for n in "${dns_entries[@]}"; do
        if [[ "$n" == "*.${domain}" ]]; then
            return 0
        fi
    done
    return 1
}

get_server_public_ip() {
    local ip
    ip="$(curl -fsS --max-time 10 http://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "$ip"
}

dig_a_records() {
    local domain="$1" line
    while IFS= read -r line; do
        line="$(echo "$line" | tr -d '\r' | tr -d '[:space:]')"
        [[ -n "$line" && "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && echo "$line"
    done < <(dig @"${DNSServer}" +short +time=5 +tries=2 "${domain}" A 2>/dev/null)
}

collect_a_ips() {
    local domain="$1"
    local -n _out=$2
    _out=()
    mapfile -t _out < <(dig_a_records "$domain")
}

a_list_contains_ip() {
    local needle="$1"
    shift
    local ip
    for ip in "$@"; do
        [[ "$ip" == "$needle" ]] && return 0
    done
    return 1
}

format_a_ips_list() {
    local -a ips=("$@")
    if [[ ${#ips[@]} -eq 0 ]]; then
        echo "(no A via @${DNSServer})"
        return 0
    fi
    (IFS=', '; echo "${ips[*]}")
}

# One dig check per proxy: both log status and the result (no second pass)
verify_all_proxies_dns() {
    local server_ip="$1" proxy status resolved
    local -a ips=()
    local all_ok=1

    [[ ${#SITE_PROXIES[@]} -gt 0 ]] || return 1

    echo "DNS check via dig @${DNSServer} (A records must include ${server_ip}, extra A records are allowed):"
    for proxy in "${SITE_PROXIES[@]}"; do
        collect_a_ips "$proxy" ips
        resolved="$(format_a_ips_list "${ips[@]}")"
        if a_list_contains_ip "$server_ip" "${ips[@]}"; then
            status="OK"
        else
            status="FAIL"
            all_ok=0
        fi
        echo "  ${status}  ${proxy}  ->  ${resolved}"
    done
    echo

    [[ "$all_ok" -eq 1 ]]
}

strip_scheme() {
    local u="$1"
    u="${u#https://}"; u="${u#http://}"; u="${u%%/*}"
    echo "${u,,}"
}

ensure_global_backends() {
    mkdir -p "$(dirname "${GLOBAL_BACKENDS_FILE}")"
    if [[ -s "${GLOBAL_BACKENDS_FILE}" ]]; then
        return 0
    fi
    local url host
    : > "${GLOBAL_BACKENDS_FILE}"
    for url in "${BACKEND_SERVERS[@]}"; do
        host="$(strip_scheme "$url")"
        [[ -n "$host" ]] && echo "$host" >> "${GLOBAL_BACKENDS_FILE}"
    done
    chmod 644 "${GLOBAL_BACKENDS_FILE}"
}

read_global_backends() {
    GLOBAL_BACKENDS=()
    local line host
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(echo "$line" | tr -d '[:space:]')"
        [[ -z "$line" ]] && continue
        if [[ "$line" == *:* ]]; then
            host="$(strip_scheme "${line#*:}")"
        else
            host="$(strip_scheme "$line")"
        fi
        [[ -n "$host" ]] && GLOBAL_BACKENDS+=("$host")
    done < "${GLOBAL_BACKENDS_FILE}"
}

site_revers_state() {
    # stdout: empty | pending | complete
    local line has=0 has_colon=0 has_plain=0
    [[ -s "${SITE_REVERS}" ]] || { echo "empty"; return; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(echo "$line" | tr -d '[:space:]')"
        [[ -z "$line" ]] && continue
        has=1
        if [[ "$line" == *:* ]]; then
            has_colon=1
        else
            has_plain=1
        fi
    done < "${SITE_REVERS}"
    [[ "$has" -eq 0 ]] && { echo "empty"; return; }
    if [[ "$has_colon" -eq 1 && "$has_plain" -eq 0 ]]; then
        echo "complete"
    else
        echo "pending"
    fi
}

read_site_proxies() {
    SITE_PROXIES=()
    local line proxy
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(echo "$line" | tr -d '[:space:]')"
        [[ -z "$line" ]] && continue
        if [[ "$line" == *:* ]]; then
            proxy="$(strip_scheme "${line%%:*}")"
        else
            proxy="$(strip_scheme "$line")"
        fi
        [[ -n "$proxy" ]] && SITE_PROXIES+=("$proxy")
    done < "${SITE_REVERS}"
}

write_site_revers_map() {
    local -a backends=("${GLOBAL_BACKENDS[@]}")
    local backend_host proxy_fqdn n=0

    if [[ ${#backends[@]} -eq 0 ]]; then
        echo "ERROR: empty ${GLOBAL_BACKENDS_FILE}"
        exit 1
    fi

    mkdir -p "${SITE_DIR}"
    : > "${SITE_REVERS}"
    for backend_host in "${backends[@]}"; do
        [[ -n "$backend_host" ]] || continue
        n=$((n + 1))
        proxy_fqdn="${PROXY_LABEL_PREFIX}${n}.${SITE_DOMAIN}"
        echo "${proxy_fqdn}:${backend_host}" >> "${SITE_REVERS}"
    done
    chmod 644 "${SITE_REVERS}"
}

prepare_site_proxy_list() {
    ensure_global_backends
    read_global_backends

    local state
    state="$(site_revers_state)"

    if [[ "$state" == "complete" && "${KEEP_EXISTING_MAP}" == "1" ]]; then
        return 0
    fi

    write_site_revers_map
}

wait_for_enter() {
    [[ "$AUTO_YES" == "1" ]] && return 0
    if [[ -r /dev/tty ]]; then
        read -r -p "Enter... " _ </dev/tty
    else
        read -r -p "Enter... " _ || true
    fi
}

print_dns_instructions() {
    local server_ip="$1"
    local proxy dns_where=""

    if declare -F dns_registrar_hint_ru >/dev/null 2>&1; then
        dns_where="$(dns_registrar_hint_ru "${SITE_DOMAIN}")"
        echo "${dns_where}."
        echo
    fi

    echo "In DNS for domain ${SITE_DOMAIN} create the following subdomains"
    echo "and add an A record to Killbot IP ${server_ip} (other A records to the same host are allowed):"
    echo
    for proxy in "${SITE_PROXIES[@]}"; do
        echo "  ${proxy}  A  ${server_ip}"
    done
    echo
    echo "Or a wildcard (one A ${server_ip} among *.${SITE_DOMAIN} records is enough):"
    echo "  *.${SITE_DOMAIN}  A  ${server_ip}"
    echo
    echo "This hides Killbot behind your site domains."
    echo "Subdomain names are fixed: ${PROXY_LABEL_PREFIX}1, ${PROXY_LABEL_PREFIX}2, … (see ${SITE_REVERS})."
    echo "Format of ${SITE_REVERS}: proxy.${SITE_DOMAIN}:backend (for check_killbot_reverse_proxy.sh)."
    echo
    echo "Manual check: dig @${DNSServer} +short r1.${SITE_DOMAIN} A"
    echo
    echo "After DNS is set, run again:"
    if [[ "$AUTO_YES" == "1" ]]; then
        echo "  sudo bash $0 ${SITE_DOMAIN} -y"
    else
        echo "  sudo bash $0 ${SITE_DOMAIN}"
    fi
    echo
    wait_for_enter
}

handle_proxies_dns_failure() {
    local server_ip="$1"
    remove_reverse_proxy_nginx_configs 1
    print_dns_instructions "${server_ip}"
    exit 0
}

parse_pair_line() {
    local line="$1" proxy_var="$2" backend_var="$3"
    local p b
    line="${line%%#*}"
    line="$(echo "$line" | tr -d '[:space:]')"
    [[ -z "$line" || "$line" != *:* ]] && return 1
    p="$(strip_scheme "${line%%:*}")"
    b="$(strip_scheme "${line#*:}")"
    [[ -z "$p" || -z "$b" ]] && return 1
    printf -v "$proxy_var" '%s' "$p"
    printf -v "$backend_var" '%s' "$b"
}

write_nginx_site() {
    local proxy_fqdn="$1" backend_host="$2"
    local conf_name="${REVERSE_PROXY_CONF_PREFIX}${proxy_fqdn}.conf"
    local conf_path="${NGINX_SITES_AVAILABLE}/${conf_name}"
    local legacy_path="${NGINX_SITES_AVAILABLE}/${proxy_fqdn}.conf"

    rm -f "${legacy_path}" "${NGINX_SITES_ENABLED}/${proxy_fqdn}.conf"

    cat > "${conf_path}" <<EOF
# ${proxy_fqdn} -> https://${backend_host}
server {
    listen 80;
    server_name ${proxy_fqdn};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${proxy_fqdn};
    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    location / {
        proxy_pass https://${backend_host};
        proxy_ssl_server_name on;
        proxy_ssl_name ${backend_host};
        proxy_ssl_verify off;
        proxy_set_header Host ${backend_host};
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    ln -sf "${conf_path}" "${NGINX_SITES_ENABLED}/${conf_name}"
}

apply_nginx() {
    local line proxy backend
    command -v nginx >/dev/null 2>&1 || { echo "ERROR: nginx is required"; exit 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        parse_pair_line "$line" proxy backend || continue
        write_nginx_site "$proxy" "$backend"
    done < "${SITE_REVERS}"
}

reload_nginx() {
    local nginx_check nginx_exit=0
    nginx_check="$(nginx -t 2>&1)" || nginx_exit=$?
    if [[ "$nginx_exit" -ne 0 ]] || ! echo "$nginx_check" | grep -qiE 'syntax is ok|test is successful'; then
        echo "ERROR: nginx -t:"
        echo "$nginx_check"
        exit 1
    fi
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
}

GLOBAL_BACKENDS=()
SITE_PROXIES=()

SERVER_IP="$(get_server_public_ip)"
[[ -n "$SERVER_IP" ]] || { echo "ERROR: failed to detect the server IP"; exit 1; }

mkdir -p "${SETTINGS_BASE}" "${NGINX_SITES_AVAILABLE}" "${NGINX_SITES_ENABLED}"

prepare_site_proxy_list

ensure_global_backends
read_global_backends
read_site_proxies

if [[ ${#SITE_PROXIES[@]} -eq 0 ]]; then
    echo "ERROR: empty ${SITE_REVERS}"
    exit 1
fi

if ! verify_all_proxies_dns "${SERVER_IP}"; then
    handle_proxies_dns_failure "${SERVER_IP}"
fi

ensure_killbot_wildcard_ssl_or_abort

apply_nginx
reload_nginx

echo "OK ${SITE_DOMAIN} — nginx reverse proxy is configured, ${SITE_REVERS}"
