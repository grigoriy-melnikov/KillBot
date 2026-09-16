#!/bin/bash

set -euo pipefail

ROTATE_CHAIN="KB_POSTROUTING_ROTATE"
LOCK_FILE="/var/lock/killbot-check-host.lock"
LOG_FILE="/var/log/killbot/check_host_curl.log"
FALLBACK_LOG_FILE="/tmp/check_host_curl.log"

LAST_HTTP_CODE="000"

init_log() {
    local log_dir
    log_dir=$(dirname "$LOG_FILE")

    if ! mkdir -p "$log_dir" 2>/dev/null || ! touch "$LOG_FILE" 2>/dev/null; then
        LOG_FILE="$FALLBACK_LOG_FILE"
        touch "$LOG_FILE" 2>/dev/null || true
    fi

    chmod 666 "$LOG_FILE" 2>/dev/null || true
}

log_msg() {
    {
        printf '[%s] %s\n' "$(date '+%F %T')" "$*"
    } >> "$LOG_FILE" 2>/dev/null || {
        printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$FALLBACK_LOG_FILE" 2>/dev/null || true
    }
}

curl_exit_name() {
    case "$1" in
        0) printf 'OK' ;;
        6) printf 'COULDNT_RESOLVE_HOST' ;;
        7) printf 'COULDNT_CONNECT' ;;
        28) printf 'OPERATION_TIMEDOUT' ;;
        35) printf 'SSL_CONNECT_ERROR' ;;
        45) printf 'BIND_FAILED_CANNOT_ASSIGN_ADDRESS' ;;
        52) printf 'GOT_NOTHING' ;;
        56) printf 'RECV_ERROR' ;;
        *) printf 'ERR_%s' "$1" ;;
    esac
}

is_local_ipv4() {
    local ip=$1
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$ip"
}

if [ "$#" -lt 5 ]; then
    echo "Usage: $0 <source_ip|-> <backend_ip> <port> <url> <host> [protocol]" >&2
    exit 1
fi

SOURCE_IP=$1
BACKEND_IP=$2
PORT=$3
URL=$4
HOST=$5
PROTOCOL=${6:-https}

RETURN_PORTS=()
RULES_ADDED=0
BROWSER_PROFILE=0
USE_SOURCE_BIND=0
SOURCE_IP_LABEL="auto"

if [ "$PROTOCOL" = "https" ]; then
    RETURN_PORTS=(443)
else
    RETURN_PORTS=("$PORT")
fi

init_log

if [ "$SOURCE_IP" = "-" ] || [ -z "$SOURCE_IP" ]; then
  SOURCE_IP=""
  USE_SOURCE_BIND=0
  log_msg "INFO no source_ip, curl without --interface"
elif [[ "$SOURCE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && is_local_ipv4 "$SOURCE_IP"; then
  USE_SOURCE_BIND=1
  SOURCE_IP_LABEL="$SOURCE_IP"
else
  local_ips_list=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')
  log_msg "WARN source_ip=$SOURCE_IP is not assigned to this server, curl without --interface. local_ips=[$local_ips_list]"
  USE_SOURCE_BIND=0
  SOURCE_IP_LABEL="${SOURCE_IP:-auto}"
fi

cleanup() {
    local dport
    if [ "$RULES_ADDED" -eq 1 ]; then
        for dport in "${RETURN_PORTS[@]}"; do
            while iptables -t nat -C "$ROTATE_CHAIN" -s "$SOURCE_IP" -d "$BACKEND_IP" -p tcp --dport "$dport" -j RETURN &>/dev/null; do
                iptables -t nat -D "$ROTATE_CHAIN" -s "$SOURCE_IP" -d "$BACKEND_IP" -p tcp --dport "$dport" -j RETURN &>/dev/null || true
            done
        done
        log_msg "iptables RETURN removed src=$SOURCE_IP dst=$BACKEND_IP ports=${RETURN_PORTS[*]}"
    fi
}

pick_browser_profile() {
    BROWSER_PROFILE=$((RANDOM % 8))

    case "$BROWSER_PROFILE" in
        0)
            BROWSER_UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36'
            BROWSER_ACCEPT='text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8'
            BROWSER_LANG='ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7'
            BROWSER_SEC_CH_UA='"Chromium";v="127", "Not)A;Brand";v="99", "Google Chrome";v="127"'
            BROWSER_SEC_CH_UA_MOBILE='?0'
            BROWSER_SEC_CH_UA_PLATFORM='"Windows"'
            ;;
        1)
            BROWSER_UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0'
            BROWSER_ACCEPT='text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7'
            BROWSER_LANG='ru,en;q=0.9,en-US;q=0.8'
            BROWSER_SEC_CH_UA='"Chromium";v="126", "Microsoft Edge";v="126", "Not)A;Brand";v="99"'
            BROWSER_SEC_CH_UA_MOBILE='?0'
            BROWSER_SEC_CH_UA_PLATFORM='"Windows"'
            ;;
        2)
            BROWSER_UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36'
            BROWSER_ACCEPT='text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'
            BROWSER_LANG='en-US,en;q=0.9,ru;q=0.8'
            BROWSER_SEC_CH_UA='"Chromium";v="127", "Not)A;Brand";v="99", "Google Chrome";v="127"'
            BROWSER_SEC_CH_UA_MOBILE='?0'
            BROWSER_SEC_CH_UA_PLATFORM='"macOS"'
            ;;
        3)
            BROWSER_UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15'
            BROWSER_ACCEPT='text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
            BROWSER_LANG='ru-RU,ru;q=0.8,en-US;q=0.5'
            BROWSER_SEC_CH_UA=''
            BROWSER_SEC_CH_UA_MOBILE=''
            BROWSER_SEC_CH_UA_PLATFORM=''
            ;;
        4)
            BROWSER_UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0'
            BROWSER_ACCEPT='text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'
            BROWSER_LANG='ru-RU,ru;q=0.8,en-US;q=0.5,en;q=0.3'
            BROWSER_SEC_CH_UA=''
            BROWSER_SEC_CH_UA_MOBILE=''
            BROWSER_SEC_CH_UA_PLATFORM=''
            ;;
        5)
            BROWSER_UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36'
            BROWSER_ACCEPT='text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8'
            BROWSER_LANG='en-US,en;q=0.9'
            BROWSER_SEC_CH_UA='"Chromium";v="127", "Not)A;Brand";v="99", "Google Chrome";v="127"'
            BROWSER_SEC_CH_UA_MOBILE='?0'
            BROWSER_SEC_CH_UA_PLATFORM='"Linux"'
            ;;
        6)
            BROWSER_UA='Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Mobile Safari/537.36'
            BROWSER_ACCEPT='text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8'
            BROWSER_LANG='ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7'
            BROWSER_SEC_CH_UA='"Chromium";v="127", "Not)A;Brand";v="99", "Google Chrome";v="127"'
            BROWSER_SEC_CH_UA_MOBILE='?1'
            BROWSER_SEC_CH_UA_PLATFORM='"Android"'
            ;;
        7)
            BROWSER_UA='Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1'
            BROWSER_ACCEPT='text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
            BROWSER_LANG='ru-RU,ru;q=0.8,en-US;q=0.5'
            BROWSER_SEC_CH_UA=''
            BROWSER_SEC_CH_UA_MOBILE=''
            BROWSER_SEC_CH_UA_PLATFORM=''
            ;;
    esac
}

run_curl() {
    local attempt=$1
    local err_file curl_exit curl_raw http_code time_total num_redirects url_effective remote_ip exit_label

    pick_browser_profile
    err_file=$(mktemp)

    local curl_opts=(
        -s -L -o /dev/null
        --http1.1
        --compressed
        --no-keepalive
        --connect-timeout 15
        --max-time 25
        -A "$BROWSER_UA"
        -H "Host: ${HOST}"
        -H "Accept: ${BROWSER_ACCEPT}"
        -H "Accept-Language: ${BROWSER_LANG}"
        -H 'Cache-Control: max-age=0'
        -H 'Connection: close'
        -H 'Upgrade-Insecure-Requests: 1'
        -H 'Sec-Fetch-Dest: document'
        -H 'Sec-Fetch-Mode: navigate'
        -H 'Sec-Fetch-Site: none'
        -H 'Sec-Fetch-User: ?1'
        -H 'DNT: 1'
        -w 'code=%{http_code} time=%{time_total} redirects=%{num_redirects} effective=%{url_effective} remote=%{remote_ip}'
    )

    if [ -n "$BROWSER_SEC_CH_UA" ]; then
        curl_opts+=(-H "sec-ch-ua: ${BROWSER_SEC_CH_UA}")
        curl_opts+=(-H "sec-ch-ua-mobile: ${BROWSER_SEC_CH_UA_MOBILE}")
        curl_opts+=(-H "sec-ch-ua-platform: ${BROWSER_SEC_CH_UA_PLATFORM}")
    fi

    if [ "$PROTOCOL" = "https" ]; then
        curl_opts+=(-k --proto '=https' --proto-redir '=https')
        curl_opts+=(--connect-to "${HOST}:443:${BACKEND_IP}:443")
    else
        curl_opts+=(--connect-to "${HOST}:80:${BACKEND_IP}:80")
    fi

    if [ "$USE_SOURCE_BIND" -eq 1 ]; then
        curl_opts+=(--interface "$SOURCE_IP")
    fi

    log_msg "attempt=$attempt start profile=$BROWSER_PROFILE bind=$USE_SOURCE_BIND src=$SOURCE_IP_LABEL dst=$BACKEND_IP host=$HOST url=$URL protocol=$PROTOCOL ua=$BROWSER_UA"

    set +e
    curl_raw=$(curl "${curl_opts[@]}" "$URL" 2>"$err_file")
    curl_exit=$?
    set -e

    http_code=$(echo "$curl_raw" | sed -n 's/.*code=\([0-9]\{3\}\).*/\1/p' | tail -1)
    time_total=$(echo "$curl_raw" | sed -n 's/.*time=\([^ ]*\).*/\1/p' | tail -1)
    num_redirects=$(echo "$curl_raw" | sed -n 's/.*redirects=\([^ ]*\).*/\1/p' | tail -1)
    url_effective=$(echo "$curl_raw" | sed -n 's/.*effective=\([^ ]*\).*/\1/p' | tail -1)
    remote_ip=$(echo "$curl_raw" | sed -n 's/.*remote=\([^ ]*\).*/\1/p' | tail -1)
    http_code=${http_code:-000}
    exit_label=$(curl_exit_name "$curl_exit")

    log_msg "attempt=$attempt result code=$http_code curl_exit=$curl_exit($exit_label) time=${time_total:-?}s redirects=${num_redirects:-?} remote=${remote_ip:-?} effective=${url_effective:-?}"
    if [ -s "$err_file" ]; then
        log_msg "attempt=$attempt curl_stderr=$(tr '\n' ' ' < "$err_file")"
    fi

    rm -f "$err_file"
    LAST_HTTP_CODE="$http_code"
}

is_valid_code() {
    [[ "$1" =~ ^[0-9]{3}$ ]] && [ "$1" != "000" ]
}

log_msg "=== check_host start pid=$$ user=$(id -un 2>/dev/null || echo unknown) log=$LOG_FILE src=$SOURCE_IP_LABEL dst=$BACKEND_IP port=$PORT host=$HOST url=$URL protocol=$PROTOCOL bind=$USE_SOURCE_BIND ==="

mkdir -p /var/lock
exec 9>"$LOCK_FILE"
if ! flock -w 30 9; then
    log_msg "ERROR flock timeout lock=$LOCK_FILE"
    printf '0\n'
    exit 0
fi

trap cleanup EXIT

if [ "$USE_SOURCE_BIND" -eq 1 ] && iptables -t nat -L "$ROTATE_CHAIN" -n &>/dev/null; then
    for dport in "${RETURN_PORTS[@]}"; do
        iptables -t nat -I "$ROTATE_CHAIN" 1 -s "$SOURCE_IP" -d "$BACKEND_IP" -p tcp --dport "$dport" -j RETURN &>/dev/null
        log_msg "iptables RETURN added src=$SOURCE_IP dst=$BACKEND_IP dport=$dport"
    done
    RULES_ADDED=1
elif [ "$USE_SOURCE_BIND" -eq 1 ]; then
    log_msg "iptables chain $ROTATE_CHAIN not found, skip RETURN"
else
    log_msg "no source bind, skip iptables RETURN"
fi

HTTP_CODE="000"
for attempt in 1 2 3; do
    run_curl "$attempt"
    HTTP_CODE=$(echo "$LAST_HTTP_CODE" | tr -d '[:space:]')
    if is_valid_code "$HTTP_CODE"; then
        log_msg "attempt=$attempt success code=$HTTP_CODE"
        break
    fi
    log_msg "attempt=$attempt failed code=$HTTP_CODE, retrying..."
    sleep "0.$(( (RANDOM % 7) + 2 ))"
done

if is_valid_code "$HTTP_CODE"; then
    log_msg "=== check_host done OK code=$HTTP_CODE ==="
    printf '%s\n' "$HTTP_CODE"
else
    log_msg "=== check_host done FAIL final_code=$HTTP_CODE ==="
    printf '0\n'
fi
