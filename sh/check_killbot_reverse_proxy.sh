#!/bin/bash
#
# 1) /opt/killbot/killbot_revers — backend -> killbot_revers_checked
#
# 2) /opt/killbot/settings/DOMAIN/killbot_revers — proxy:backend
#    proxy (r1.DOMAIN, …) -> killbot_revers_checked
#    Wildcard cert is required in /opt/killbot/ssl/DOMAIN/fullchain.pem; otherwise revers/checked are removed
#
# DNS: first the zone's authoritative NS, otherwise @8.8.8.8.
# For a proxy site: A records must include this Killbot server IP (PROXY_SERVER_IP).
# For each IP from dig — GET /ping with Host/SNI of the host (--resolve).
# Write to checked only if ALL IPs returned 200 and ok1.
#
# Usage: sudo bash check_killbot_reverse_proxy.sh
#
# Only one instance at a time (flock). A stale lock is dropped if the PID is dead.
# Cron: * * * * * /opt/killbot/check_killbot_reverse_proxy.sh
#
set -euo pipefail

LOCK_FILE="${LOCK_FILE:-/var/run/check_killbot_reverse_proxy.lock}"
LOCK_PID_FILE="${LOCK_PID_FILE:-${LOCK_FILE}.pid}"

lock_log() {
    echo "$(date '+%F %T') - $*"
}

lock_holder_pid() {
    local pid=""
    [[ -f "$LOCK_PID_FILE" ]] || return 1
    pid=$(tr -d '[:space:]' <"$LOCK_PID_FILE" 2>/dev/null || true)
    [[ -n "$pid" ]] || return 1
    echo "$pid"
}

lock_holder_alive() {
    local pid="$1"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

other_script_pids() {
    pgrep -f '[c]heck_killbot_reverse_proxy\.sh' 2>/dev/null | grep -vx "$$" || true
}

release_lock_fd() {
    exec 9>&- 2>/dev/null || true
}

remove_stale_lock() {
    local pid="" pids=""

    pid=$(lock_holder_pid 2>/dev/null || true)

    if lock_holder_alive "$pid"; then
        return 1
    fi

    if [[ -n "$pid" ]]; then
        lock_log "WARNING: stale lock (PID ${pid} not running), removing lock"
    elif [[ -f "$LOCK_FILE" ]]; then
        pids=$(other_script_pids)
        if [[ -n "$pids" ]]; then
            return 1
        fi
        lock_log "WARNING: orphan lock without live PID, removing lock"
    else
        return 1
    fi

    release_lock_fd
    rm -f "$LOCK_FILE" "$LOCK_PID_FILE"
    return 0
}

try_acquire_run_lock() {
    exec 9>"$LOCK_FILE"
    flock -n 9
}

acquire_run_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true

    if try_acquire_run_lock; then
        echo "$$" >"$LOCK_PID_FILE"
        return 0
    fi

    release_lock_fd

    if remove_stale_lock && try_acquire_run_lock; then
        lock_log "Lock re-acquired after stale cleanup"
        echo "$$" >"$LOCK_PID_FILE"
        return 0
    fi

    release_lock_fd
    lock_log "Another instance is already running (lock: ${LOCK_FILE}), exit"
    exit 0
}

acquire_run_lock

GLOBAL_BACKENDS_FILE="${GLOBAL_BACKENDS_FILE:-/opt/killbot/killbot_revers}"
GLOBAL_CHECKED_FILE="${GLOBAL_CHECKED_FILE:-/opt/killbot/killbot_revers_checked}"
SETTINGS_BASE="${SETTINGS_BASE:-/opt/killbot/settings}"
SSL_BASE_DIR="${SSL_BASE_DIR:-/opt/killbot/ssl}"
DNSServer="${DNSServer:-8.8.8.8}"
PING_TIMEOUT="${PING_TIMEOUT:-6}"
PING_EXPECT_BODY="${PING_EXPECT_BODY:-ok1.}"
PING_VERIFY_SSL="${PING_VERIFY_SSL:-1}"
PROXY_SERVER_IP="${PROXY_SERVER_IP:-}"

DEFAULT_BACKEND_URLS=(
    "https://10052024.ru"
    "https://r1.kill-bot.ru"
    "https://data.killbot.ru"
    "https://r3.nl.kill-bot.ru"
    "https://r4.us.kill-bot.ru"
    "https://r6.sg.kill-bot.net"
)

DIG_LAST_RESOLVER=""

normalize_host() {
    local h="$1"
    h="${h#https://}"; h="${h#http://}"; h="${h%%/*}"; h="${h%/}"
    echo "${h,,}"
}

normalize_ns() {
    local ns="$1"
    ns="${ns%.}"
    ns="${ns,,}"
    echo "$ns"
}

get_server_public_ip() {
    local ip
    ip="$(curl -fsS --max-time 10 http://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "$ip"
}

init_global_backends_if_empty() {
    mkdir -p "$(dirname "${GLOBAL_BACKENDS_FILE}")"
    [[ -s "${GLOBAL_BACKENDS_FILE}" ]] && return 0
    : > "${GLOBAL_BACKENDS_FILE}"
    local url host
    for url in "${DEFAULT_BACKEND_URLS[@]}"; do
        host="$(normalize_host "$url")"
        [[ -n "$host" ]] && echo "$host" >> "${GLOBAL_BACKENDS_FILE}"
    done
    chmod 644 "${GLOBAL_BACKENDS_FILE}" 2>/dev/null || true
}

dns_apex_zone() {
    local host="$1" d ns_line
    host="$(normalize_host "$host")"
    d="$host"
    while [[ "$d" == *.* ]]; do
        while IFS= read -r ns_line; do
            [[ -n "$ns_line" ]] && echo "$d" && return 0
        done < <(dig +short NS "${d}" 2>/dev/null)
        d="${d#*.}"
    done
    echo "$host"
}

pick_authoritative_ns() {
    local apex="$1" ns
    while IFS= read -r ns; do
        ns="$(normalize_ns "$ns")"
        [[ -n "$ns" ]] && echo "$ns" && return 0
    done < <(dig +short NS "${apex}" 2>/dev/null)
    echo "${DNSServer}"
}

dig_query_a_at() {
    local resolver="$1" domain="$2" line
    while IFS= read -r line; do
        line="$(echo "$line" | tr -d '\r' | tr -d '[:space:]')"
        [[ -n "$line" && "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && echo "$line"
    done < <(dig @"${resolver}" +short +time=5 +tries=2 "${domain}" A 2>/dev/null)
}

collect_a_ips() {
    local domain="$1"
    local -n _out=$2
    local apex resolver
    local -a from_auth=() from_pub=()

    _out=()
    domain="$(normalize_host "$domain")"
    [[ -n "$domain" ]] || return 0

    apex="$(dns_apex_zone "$domain")"
    resolver="$(pick_authoritative_ns "$apex")"

    mapfile -t from_auth < <(dig_query_a_at "$resolver" "$domain")

    if [[ ${#from_auth[@]} -gt 0 ]]; then
        _out=("${from_auth[@]}")
        DIG_LAST_RESOLVER="${resolver}"
        return 0
    fi

    if [[ "$resolver" != "${DNSServer}" ]]; then
        mapfile -t from_pub < <(dig_query_a_at "${DNSServer}" "$domain")
        if [[ ${#from_pub[@]} -gt 0 ]]; then
            _out=("${from_pub[@]}")
            DIG_LAST_RESOLVER="${DNSServer} (fallback, NS ${resolver} has no A)"
            return 0
        fi
    fi

    DIG_LAST_RESOLVER="${resolver}"
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

format_ip_list() {
    local -a ips=("$@")
    if [[ ${#ips[@]} -eq 0 ]]; then
        echo "(no A)"
        return 0
    fi
    (IFS=', '; echo "${ips[*]}")
}

# GET https://host/ping via a specific IP, Host and SNI = host
ping_ok_via_ip() {
    local host="$1" ip="$2"
    local code body tmp curl_err=0
    local -a curl_opts=(
        -sS
        -w '%{http_code}'
        --connect-timeout "${PING_TIMEOUT}"
        --max-time "${PING_TIMEOUT}"
        --proto '=https'
        --resolve "${host}:443:${ip}"
    )

    tmp="$(mktemp)"
    curl_opts+=(-o "$tmp")

    if [[ "${PING_VERIFY_SSL}" == "1" ]]; then
        curl_opts+=(--ssl-reqd)
    else
        curl_opts+=(-k)
    fi

    code="$(curl "${curl_opts[@]}" "https://${host}/ping" 2>/dev/null)" || curl_err=$?

    body="$(tr -d '\r' < "$tmp" | sed 's/[[:space:]]*$//')"
    rm -f "$tmp"

    [[ "$curl_err" -eq 0 && "$code" == "200" && "$body" == "${PING_EXPECT_BODY}" ]]
}

# required_ip — for proxy: required A record IP of the Killbot server (may be among several A records)
host_all_ips_ping_ok() {
    local host="$1"
    local required_ip="${2:-}"
    local ip ip_list
    local -a ips=()

    host="$(normalize_host "$host")"
    [[ -n "$host" ]] || return 1

    collect_a_ips "$host" ips
    ip_list="$(format_ip_list "${ips[@]}")"

    if [[ ${#ips[@]} -eq 0 ]]; then
        echo "  FAIL ${host} — no A (dig: ${DIG_LAST_RESOLVER})" >&2
        return 1
    fi

    if [[ -n "$required_ip" ]] && ! a_list_contains_ip "$required_ip" "${ips[@]}"; then
        echo "  FAIL ${host} — no A ${required_ip} among [${ip_list}] (dig: ${DIG_LAST_RESOLVER})" >&2
        return 1
    fi

    echo "  DNS  ${host} -> [${ip_list}] (${DIG_LAST_RESOLVER})" >&2

    for ip in "${ips[@]}"; do
        if ping_ok_via_ip "$host" "$ip"; then
            echo "  OK   ${host} @${ip}" >&2
        else
            echo "  FAIL ${host} @${ip} — /ping is not 200/${PING_EXPECT_BODY}" >&2
            return 1
        fi
    done
    return 0
}

url_if_host_pings() {
    local host="$1"
    local required_ip="${2:-}"
    local url
    host="$(normalize_host "$host")"
    [[ -z "$host" ]] && return 1
    host_all_ips_ping_ok "$host" "$required_ip" || return 1
    url="https://${host}"
    echo "$url"
}

write_checked_if_changed() {
    local tmp="$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    if [[ ! -s "$tmp" ]]; then
        if [[ -f "$dest" ]]; then
            rm -f "$dest"
            echo "Removed ${dest}"
        fi
        return 1
    fi
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 0
    fi
    mv -f "$tmp" "$dest"
    chmod 644 "$dest" 2>/dev/null || true
    echo "Updated ${dest}"
    cat "$dest"
    return 0
}

check_global_backends() {
    local line host url tmp
    tmp="$(mktemp)"
    init_global_backends_if_empty

    echo "=== ${GLOBAL_BACKENDS_FILE} (auth NS / @${DNSServer}, all A -> /ping) ==="
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(echo "$line" | tr -d '[:space:]')"
        [[ -z "$line" ]] && continue
        host="$(normalize_host "$line")"
        [[ -z "$host" ]] && continue
        if url="$(url_if_host_pings "$host")"; then
            echo "${url}" >> "$tmp"
        fi
    done < "${GLOBAL_BACKENDS_FILE}"

    if write_checked_if_changed "$tmp" "${GLOBAL_CHECKED_FILE}"; then
        :
    else
        echo "WARNING: no working backends in ${GLOBAL_BACKENDS_FILE}"
    fi
    [[ -f "$tmp" ]] && rm -f "$tmp"
    return 0
}

# SAN *.domain in /opt/killbot/ssl/{domain}/fullchain.pem (same as kb_install.sh)
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

remove_site_reverse_proxy_files() {
    local domain="$1"
    local revers_file="${SETTINGS_BASE}/${domain}/killbot_revers"
    local checked_file="${SETTINGS_BASE}/${domain}/killbot_revers_checked"
    local removed=0

    if [[ -f "$revers_file" ]]; then
        rm -f "$revers_file"
        removed=1
    fi
    if [[ -f "$checked_file" ]]; then
        rm -f "$checked_file"
        removed=1
    fi

    if [[ "$removed" -eq 1 ]]; then
        echo "Removed reverse-proxy files for ${domain} (no wildcard in ${SSL_BASE_DIR}/${domain}/fullchain.pem)"
    fi
}

ensure_site_wildcard_ssl() {
    local domain="$1"
    local certfile="${SSL_BASE_DIR}/${domain}/fullchain.pem"

    if is_wildcard_cert "$certfile" "$domain"; then
        return 0
    fi

    remove_site_reverse_proxy_files "$domain"
    echo "=== ${domain} — skip (no wildcard *.${domain} in ${certfile}) ==="
    return 1
}

site_revers_has_proxy_backend_pairs() {
    local revers_file="$1" line has=0
    [[ -s "$revers_file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(echo "$line" | tr -d '[:space:]')"
        [[ -z "$line" ]] && continue
        has=1
        [[ "$line" != *:* ]] && return 1
    done < "$revers_file"
    [[ "$has" -eq 1 ]]
}

check_site_revers() {
    local site_dir="$1" site_domain revers_file checked_file tmp
    local line proxy url server_ip

    site_domain="$(basename "$site_dir")"
    revers_file="${site_dir}/killbot_revers"
    checked_file="${site_dir}/killbot_revers_checked"

    if ! ensure_site_wildcard_ssl "$site_domain"; then
        return 0
    fi

    [[ -f "$revers_file" && -s "$revers_file" ]] || return 0

    if ! site_revers_has_proxy_backend_pairs "$revers_file"; then
        echo "=== ${site_domain} — skip (killbot_revers has no proxy:backend lines) ==="
        return 0
    fi

    server_ip="${PROXY_SERVER_IP:-$(get_server_public_ip)}"
    if [[ -z "$server_ip" ]]; then
        echo "=== ${site_domain} — skip (PROXY_SERVER_IP is not set) ===" >&2
        return 0
    fi

    echo "=== ${site_domain} (requires A ${server_ip} + all A -> /ping) ==="
    tmp="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(echo "$line" | tr -d '[:space:]')"
        [[ -z "$line" || "$line" != *:* ]] && continue
        proxy="$(normalize_host "${line%%:*}")"
        [[ -z "$proxy" ]] && continue
        if url="$(url_if_host_pings "$proxy" "$server_ip")"; then
            echo "${url}" >> "$tmp"
        fi
    done < "$revers_file"

    if write_checked_if_changed "$tmp" "$checked_file"; then
        :
    else
        echo "WARNING: no working proxies for ${site_domain}"
    fi
    [[ -f "$tmp" ]] && rm -f "$tmp"
    return 0
}

command -v dig >/dev/null 2>&1 || { echo "ERROR: dig is required (dnsutils)" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl is required" >&2; exit 1; }

PROXY_SERVER_IP="${PROXY_SERVER_IP:-$(get_server_public_ip)}"

check_global_backends || true

if [[ -d "${SETTINGS_BASE}" ]]; then
    for site_dir in "${SETTINGS_BASE}"/*/; do
        [[ -d "$site_dir" ]] || continue
        check_site_revers "$site_dir" || true
    done
fi
