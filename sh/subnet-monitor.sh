#!/bin/bash

# Script to block /24 and /16 subnets with a whitelist
# Version: hardened (fixed bash arithmetic, nullglob, get_time_ago)

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export SHELL=/bin/bash
export LANG=en_US.UTF-8

# IMPORTANT: so the LOG_FILES glob does not stay a literal string when there are no files
shopt -s nullglob

# ================== DEFAULT SETTINGS ==================
# These values are overridden from the config if it exists
#DEFAULT_LOG_FILES="/var/log/apache2/*.access.log"
DEFAULT_LOG_FILES="/var/log/nginx/access.log"
DEFAULT_THRESHOLD24=2000
DEFAULT_THRESHOLD16=5000
DEFAULT_THRESHOLDIP=1000
DEFAULT_BAN_TIME=3600
DEFAULT_BLOCK_MODE="all"  # Can be: "all", "24only", "16only", "ip"
DEFAULT_LOG_WINDOW_SECONDS=60

# Configuration files
CONFIG_FILE="/opt/killbot/f2b/subnet-monitor.conf"
WHITELIST_FILE="/opt/killbot/f2b/subnet-monitor-whitelist.conf"

# Initialize variables with defaults
LOG_FILES="$DEFAULT_LOG_FILES"
THRESHOLD24="$DEFAULT_THRESHOLD24"
THRESHOLD16="$DEFAULT_THRESHOLD16"
THRESHOLDIP="$DEFAULT_THRESHOLDIP"
BAN_TIME="$DEFAULT_BAN_TIME"
BLOCK_MODE="$DEFAULT_BLOCK_MODE"
LOG_WINDOW_SECONDS="$DEFAULT_LOG_WINDOW_SECONDS"

# ================== LOAD CONFIGURATION ==================
# Create the config directory if it does not exist
mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null

# If the config exists, load it
if [ -f "$CONFIG_FILE" ]; then
    # Migrate old configs: if THRESHOLDIP is missing, this is an old version.
    # Delete the config so a new one with current variables is created below.
    if ! grep -qE '^[[:space:]]*THRESHOLDIP[[:space:]]*=' "$CONFIG_FILE" 2>/dev/null; then
        rm -f "$CONFIG_FILE"
    fi
fi

# If the config exists, load it
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    # Create a config with default values
    cat > "$CONFIG_FILE" << EOF
# Configuration for subnet-monitor
# Created: $(date)

# Path to log files (globs are allowed)
LOG_FILES="$DEFAULT_LOG_FILES"

# Block thresholds
THRESHOLD24=$DEFAULT_THRESHOLD24
THRESHOLD16=$DEFAULT_THRESHOLD16
THRESHOLDIP=$DEFAULT_THRESHOLDIP

# Block duration in seconds
BAN_TIME=$DEFAULT_BAN_TIME

# Log analysis window (seconds). The tail is analyzed: from the last log record minus LOG_WINDOW_SECONDS.
LOG_WINDOW_SECONDS=$DEFAULT_LOG_WINDOW_SECONDS

# Block mode: all, 24only, 16only, ip
BLOCK_MODE="$DEFAULT_BLOCK_MODE"

# Path to the whitelist file
WHITELIST_FILE="$WHITELIST_FILE"
EOF
    echo "Configuration file created: $CONFIG_FILE"
fi

# ================== WHITELIST ==================
# Create the whitelist file if it is missing
if [ ! -f "$WHITELIST_FILE" ]; then
    mkdir -p "$(dirname "$WHITELIST_FILE")" 2>/dev/null
    cat > "$WHITELIST_FILE" << 'EOF'
# Subnet whitelist for subnet-monitor.sh
# Only /24 and /16 masks are supported. Any other masks are NOT supported.
# To allow a single IP, add it to the list WITHOUT a /32 mask
127.0.0.0/24
127.0.0.0/16
10.0.0.0/16
10.0.0.0/24
192.168.0.0/16
192.168.0.0/24
192.168.1.0/16
192.168.1.0/24
192.168.0.1
192.168.0.0
192.168.1.0
192.168.1.1
127.0.0.1
127.0.0.2
31.211.65.236
EOF
    echo "Whitelist file created: $WHITELIST_FILE"
fi

# ================== OTHER SETTINGS ==================
BAN_LOG="/var/log/killbot/subnet-block.log"
UNBAN_LOG="/var/log/killbot/subnet-unban.log"
DEBUG_LOG="/var/log/killbot/subnet-debug.log"
STATS_LOG="/var/log/killbot/subnet-stats.log"
IPTABLES_CHAIN="INPUT"
PIDFILE="/tmp/subnet-monitor.pid"
BAN_FILE="/tmp/subnet_bans"
IPTABLES_COMMENT_TAG="subnet-monitor"

# One log pass per run: raw IPs in the LOG_WINDOW_SECONDS window (default DEFAULT_LOG_WINDOW_SECONDS)
# and summary lines "count subnet mask" + associative maps SUBNET_MON_AGG_* (sum over all LOG_FILES).
# No second log parse: summarize_requests_last_window / count_requests_last_window read memory only.
# Change thresholds/BLOCK_MODE without rereading the log: recompute_summary_lines_from_raw.
declare -ga SUBNET_MON_RAW_IPS=()
declare -ga SUBNET_MON_SUMMARY_LINES=()
declare -gA SUBNET_MON_AGG_IP=()
declare -gA SUBNET_MON_AGG_S24=()
declare -gA SUBNET_MON_AGG_S16=()
SUBNET_MON_WINDOW_LOADED=0

# Whitelist and iptables-chain cache for one pass (no cat|xargs and no sudo -L per line)
declare -ga SUBNET_MON_WHITELIST_ITEMS=()
SUBNET_MON_WHITELIST_CACHE_VALID=0
SUBNET_MON_IPTABLES_LIST=""
SUBNET_MON_IPTABLES_LOADED=0

# Reliable Unix timestamp
get_timestamp() {
    date +%s 2>/dev/null || echo 0
}

# Format time for debugging
format_duration() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(( (seconds % 3600) / 60 ))
    local secs=$((seconds % 60))

    if [ $hours -gt 0 ]; then
        printf "%dh %dm %ds" $hours $minutes $secs
    elif [ $minutes -gt 0 ]; then
        printf "%dm %ds" $minutes $secs
    else
        printf "%ds" $secs
    fi
}

# ================== WHITELIST FUNCTIONS ==================

refresh_whitelist_cache() {
    SUBNET_MON_WHITELIST_ITEMS=()
    local line subnet
    for subnet in "${WHITELIST_SUBNETS[@]}"; do
        [ -n "$subnet" ] && SUBNET_MON_WHITELIST_ITEMS+=("$subnet")
    done

    if [ -f "$WHITELIST_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [ -z "$line" ] && continue

            if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] || \
               [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                SUBNET_MON_WHITELIST_ITEMS+=("$line")
            fi
        done < "$WHITELIST_FILE"
    fi
    SUBNET_MON_WHITELIST_CACHE_VALID=1
}

load_whitelist() {
    [ "${SUBNET_MON_WHITELIST_CACHE_VALID:-0}" -eq 1 ] || refresh_whitelist_cache
    echo "${SUBNET_MON_WHITELIST_ITEMS[@]}"
}

is_subnet_in_whitelist() {
    local subnet="$1" item
    [ "${SUBNET_MON_WHITELIST_CACHE_VALID:-0}" -eq 1 ] || refresh_whitelist_cache
    for item in "${SUBNET_MON_WHITELIST_ITEMS[@]}"; do
        [[ "$subnet" == "$item" ]] && return 0
    done
    return 1
}

# ================== LOCK FILE MANAGEMENT ==================

LOCK_FILES=(
    "/tmp/subnet-monitor.lock"
    "/tmp/subnet-monitor.pid"
    "/var/run/subnet-monitor.lock"
)

MAX_AGE_MINUTES=5

for lock_file in "${LOCK_FILES[@]}"; do
    if [ -f "$lock_file" ]; then
        if find "$lock_file" -mmin +$MAX_AGE_MINUTES >/dev/null 2>&1; then
            echo "$(date): Removing stale lock file: $lock_file"
            rm -f "$lock_file"
        fi
    fi
done

# Check for an already running process
if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "$(date): Process is already running (PID: $OLD_PID), exiting"
        exit 1
    else
        rm -f "$PIDFILE"
    fi
fi

# Create the PID file
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# ================== MAIN FUNCTIONS ==================

get_time_ago() {
    local seconds=$1
    # Human-readable (for tests/logs); request window — see load_access_log_window_cache
    date -d "@$(($(get_timestamp) - seconds))" '+%Y-%m-%d %H:%M:%S'
}

# Message about an excluded log: to DEBUG_LOG and stderr (for cron).
subnet_monitor_log_invalid_logfile() {
    local msg="$1"
    mkdir -p "$(dirname "$DEBUG_LOG")" 2>/dev/null
    echo "$msg" >> "$DEBUG_LOG" 2>/dev/null || true
    echo "$msg" >&2
}

# Filter access logs to the request-window format (IPv4, [nginx combined date ...]).
# Invalid paths are dropped from LOG_FILES; the script does not exit.
# Empty files: silently skipped, no log line.
validate_access_logs_format() {
    local any_file=0 valid_list="" sample f
    local orig="$LOG_FILES"

    for f in $LOG_FILES; do
        any_file=1
        if [ ! -f "$f" ]; then
            subnet_monitor_log_invalid_logfile "$(date): subnet-monitor: excluded from LOG_FILES (no such file): $f"
            continue
        fi
        if [ ! -r "$f" ]; then
            subnet_monitor_log_invalid_logfile "$(date): subnet-monitor: excluded from LOG_FILES (not readable): $f"
            continue
        fi
        if [ ! -s "$f" ]; then
            continue
        fi

        sample=$(grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$f" 2>/dev/null) || sample=""
        if [ -z "$sample" ] || ! echo "$sample" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ - - \[[0-9]{2}/[A-Za-z]{3}/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}\]'; then
            subnet_monitor_log_invalid_logfile "$(date): subnet-monitor: excluded from LOG_FILES (invalid nginx access-log format): $f"
            continue
        fi

        valid_list="${valid_list:+$valid_list }$f"
    done

    if [ "$any_file" -eq 0 ]; then
        subnet_monitor_log_invalid_logfile "$(date): subnet-monitor: LOG_FILES matched no files (glob/path): $orig"
    fi

    LOG_FILES="$valid_list"
}

# Compatibility with the old value "both" -> "all"
if [ "${BLOCK_MODE:-}" = "both" ]; then
    BLOCK_MODE="all"
fi

refresh_iptables_cache() {
    SUBNET_MON_IPTABLES_LIST=$(sudo iptables -L "$IPTABLES_CHAIN" -n 2>/dev/null || true)
    SUBNET_MON_IPTABLES_LOADED=1
}

is_subnet_banned() {
    local subnet="$1"
    [ "${SUBNET_MON_IPTABLES_LOADED:-0}" -eq 1 ] || refresh_iptables_cache
    grep -qF -- "$subnet" <<< "$SUBNET_MON_IPTABLES_LIST"
    return $?
}

is_ip_banned() {
    local ip="$1" esc
    [ "${SUBNET_MON_IPTABLES_LOADED:-0}" -eq 1 ] || refresh_iptables_cache
    esc="${ip//./\\.}"
    grep -qE "(^|[[:space:]])${esc}([[:space:]]|$)" <<< "$SUBNET_MON_IPTABLES_LIST"
    return $?
}

# Ban a subnet
ban_subnet() {
    local subnet="$1"
    local count="$2"
    local mask="$3"

    if is_subnet_in_whitelist "$subnet"; then
        echo "$(date): SKIP (whitelist): $subnet ($mask) - $count requests/${LOG_WINDOW_SECONDS}s" | tee -a "$BAN_LOG"
        return 1
    fi

    local timestamp=$(get_timestamp)
    echo "$(date): Blocking subnet $subnet ($mask) - $count requests in ${LOG_WINDOW_SECONDS} seconds" | tee -a "$BAN_LOG"

    # Block in iptables (mark with a comment so it can be removed safely later)
    sudo iptables -A "$IPTABLES_CHAIN" -s "$subnet" -m comment --comment "$IPTABLES_COMMENT_TAG" -j DROP
    refresh_iptables_cache

    # Save the ban time
    echo "$timestamp $subnet $mask" >> "$BAN_FILE"

    # Log for debugging
    echo "$(date): Banned subnet $subnet, timestamp: $timestamp" >> "$DEBUG_LOG"
}

ban_ip() {
    local ip="$1"
    local count="$2"

    if is_subnet_in_whitelist "$ip"; then
        echo "$(date): SKIP (whitelist): $ip (ip) - $count requests/${LOG_WINDOW_SECONDS}s" | tee -a "$BAN_LOG"
        return 1
    fi

    local timestamp
    timestamp=$(get_timestamp)
    echo "$(date): Blocking IP $ip - $count requests in ${LOG_WINDOW_SECONDS} seconds" | tee -a "$BAN_LOG"

    sudo iptables -A "$IPTABLES_CHAIN" -s "$ip" -m comment --comment "$IPTABLES_COMMENT_TAG" -j DROP
    refresh_iptables_cache
    echo "$timestamp $ip ip" >> "$BAN_FILE"
    echo "$(date): Banned IP $ip, timestamp: $timestamp" >> "$DEBUG_LOG"
}

# Improved unban function
unban_old_subnets() {
    local current_time=$(get_timestamp)

    if [ ! -f "$BAN_FILE" ] || [ ! -s "$BAN_FILE" ]; then
        echo "$(date): Ban file is empty or missing" >> "$DEBUG_LOG"
        return 0
    fi

    echo "$(date): Starting unban, current time: $current_time" >> "$DEBUG_LOG"
    local temp_file=$(mktemp)
    local unban_count=0

    refresh_iptables_cache

    while IFS= read -r line; do
        [ -z "$line" ] && continue

        # Parse the line: timestamp subnet mask
        local ban_time=$(echo "$line" | awk '{print $1}')
        local subnet=$(echo "$line" | awk '{print $2}')
        local mask=$(echo "$line" | awk '{print $3}')

        # Validate the data
        if [[ ! "$ban_time" =~ ^[0-9]+$ ]] || [[ -z "$subnet" ]] || [[ -z "$mask" ]]; then
            echo "$(date): Format error: $line" >> "$DEBUG_LOG"
            continue
        fi

        local time_passed=$((current_time - ban_time))

        if [ "$time_passed" -ge "$BAN_TIME" ]; then
            # Time expired, unbanning
            local duration_str=$(format_duration "$time_passed")
            echo "$(date): Unbanning $subnet (elapsed $duration_str)" >> "$UNBAN_LOG"

            # Remove from iptables (check via -n cache; re-read rule numbers on each delete)
            if grep -qF -- "$subnet" <<< "$SUBNET_MON_IPTABLES_LIST"; then
                # Find and delete all rules for this subnet
                while true; do
                    local rule_num=$(sudo iptables -L "$IPTABLES_CHAIN" --line-numbers -n 2>/dev/null | \
                                   grep "$subnet" | head -1 | awk '{print $1}')
                    [ -z "$rule_num" ] && break

                    sudo iptables -D "$IPTABLES_CHAIN" "$rule_num" 2>/dev/null && \
                    echo "$(date): Removed rule #$rule_num for $subnet" >> "$UNBAN_LOG"
                done
                refresh_iptables_cache
                unban_count=$((unban_count + 1))
            fi
        else
            # Keep for the next check
            echo "$line" >> "$temp_file"
            local time_left=$((BAN_TIME - time_passed))
            local left_str=$(format_duration "$time_left")
            echo "$(date): $subnet is still banned, remaining: $left_str" >> "$DEBUG_LOG"
        fi
    done < "$BAN_FILE"

    # Replace the ban file
    mv "$temp_file" "$BAN_FILE"

    if [ $unban_count -gt 0 ]; then
        echo "$(date): Total subnets unbanned: $unban_count" >> "$UNBAN_LOG"
    fi

    echo "$(date): Unban finished" >> "$DEBUG_LOG"
}

get_last_log_timestamp() {
    local log_file="$1"
    local last_line last_date ts

    [ -f "$log_file" ] || { echo 0; return; }
    [ -s "$log_file" ] || { echo 0; return; }

    last_line=$(tail -n 20000 "$log_file" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1) || last_line=""
    [ -n "$last_line" ] || { echo 0; return; }

    last_date=$(echo "$last_line" | awk '{print $4}' | sed 's/^\[//') || last_date=""
    [ -n "$last_date" ] || { echo 0; return; }

    ts=$(date -d "${last_date}" +%s 2>/dev/null || echo 0)
    echo "${ts:-0}"
}

# Fill SUBNET_MON_AGG_* from SUBNET_MON_SUMMARY_LINES (lines like: count subnet mask)
build_agg_maps_from_summary_lines() {
    SUBNET_MON_AGG_IP=()
    SUBNET_MON_AGG_S24=()
    SUBNET_MON_AGG_S16=()
    local line count subnet mask prev
    for line in "${SUBNET_MON_SUMMARY_LINES[@]}"; do
        read -r count subnet mask <<< "$line"
        [[ "$count" =~ ^[0-9]+$ ]] || continue
        case "$mask" in
            ip)
                prev="${SUBNET_MON_AGG_IP["$subnet"]:-0}"
                SUBNET_MON_AGG_IP["$subnet"]=$((prev + count))
                ;;
            24)
                prev="${SUBNET_MON_AGG_S24["$subnet"]:-0}"
                SUBNET_MON_AGG_S24["$subnet"]=$((prev + count))
                ;;
            16)
                prev="${SUBNET_MON_AGG_S16["$subnet"]:-0}"
                SUBNET_MON_AGG_S16["$subnet"]=$((prev + count))
                ;;
        esac
    done
}

# Once per run: tail the log into memory (raw IP list + summary lines + aggregate maps)
load_access_log_window_cache() {
    SUBNET_MON_RAW_IPS=()
    SUBNET_MON_SUMMARY_LINES=()
    SUBNET_MON_AGG_IP=()
    SUBNET_MON_AGG_S24=()
    SUBNET_MON_AGG_S16=()
    SUBNET_MON_WINDOW_LOADED=0

    local window="${LOG_WINDOW_SECONDS:-${DEFAULT_LOG_WINDOW_SECONDS:-60}}"
    local now_ts last_ts limit_ts log_file
    local -a chunk=()
    local -i i split_at=-1

    now_ts=$(date +%s)

    for log_file in $LOG_FILES; do
        [ -f "$log_file" ] || continue
        last_ts=$(get_last_log_timestamp "$log_file")
        if [ "${last_ts:-0}" -le 0 ]; then
            last_ts="$now_ts"
        fi
        limit_ts=$((last_ts - window))

        mapfile -t chunk < <(
            tail -n 200000 "$log_file" | awk \
                -v limit_ts="$limit_ts" \
                -v last_ts="$last_ts" \
                -v block_mode="$BLOCK_MODE" \
                -v thip="$THRESHOLDIP" \
                -v th24="$THRESHOLD24" \
                -v th16="$THRESHOLD16" '
            function mon2n(m) {
                m = tolower(m)
                if (m=="jan") return 1
                if (m=="feb") return 2
                if (m=="mar") return 3
                if (m=="apr") return 4
                if (m=="may") return 5
                if (m=="jun") return 6
                if (m=="jul") return 7
                if (m=="aug") return 8
                if (m=="sep") return 9
                if (m=="oct") return 10
                if (m=="nov") return 11
                if (m=="dec") return 12
                return 0
            }

            function ip2sub24(ip,    o) {
                split(ip, o, ".")
                return o[1]"."o[2]"."o[3]".0/24"
            }

            function ip2sub16(ip,    o) {
                split(ip, o, ".")
                return o[1]"."o[2]".0.0/16"
            }

            function sub24_to_sub16(sub24,    p, o) {
                split(sub24, p, "/")
                split(p[1], o, ".")
                return o[1]"."o[2]".0.0/16"
            }

            /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {
                t = $4
                gsub(/^\[/, "", t)
                split(t, a, /[:\/]/)
                if (length(a[1]) == 0) next
                day = a[1] + 0
                mon = mon2n(a[2])
                year = a[3] + 0
                hh = a[4] + 0
                mm = a[5] + 0
                ss = a[6] + 0
                if (mon == 0) next

                log_ts = mktime(sprintf("%04d %02d %02d %02d %02d %02d", year, mon, day, hh, mm, ss))
                if (log_ts < limit_ts || log_ts > last_ts) next

                ip = $1
                s24 = ip2sub24(ip)
                s16 = ip2sub16(ip)

                ipC[ip]++
                s24C[s24]++
                s16C[s16]++
                print ip
            }

            END {
                print "__SUMMARY__"

                for (s in s24C) s24Adj[s] = s24C[s]
                for (s in s16C) s16Adj[s] = s16C[s]

                if (block_mode == "ip" || block_mode == "all" || block_mode == "both") {
                    for (ip in ipC) {
                        if (ipC[ip] > thip) {
                            s24 = ip2sub24(ip)
                            s16 = ip2sub16(ip)
                            s24Adj[s24] -= ipC[ip]
                            if (s24Adj[s24] < 0) s24Adj[s24] = 0
                            s16Adj[s16] -= ipC[ip]
                            if (s16Adj[s16] < 0) s16Adj[s16] = 0
                        }
                    }
                }

                if (block_mode == "all" || block_mode == "both") {
                    for (s24 in s24Adj) {
                        if (s24Adj[s24] > th24) {
                            s16 = sub24_to_sub16(s24)
                            s16Adj[s16] -= s24Adj[s24]
                            if (s16Adj[s16] < 0) s16Adj[s16] = 0
                        }
                    }
                }

                if (block_mode == "ip") {
                    for (ip in ipC) print ipC[ip], ip, "ip"
                } else if (block_mode == "24only") {
                    for (s24 in s24C) print s24C[s24], s24, "24"
                } else if (block_mode == "16only") {
                    for (s16 in s16C) print s16C[s16], s16, "16"
                } else {
                    for (ip in ipC) print ipC[ip], ip, "ip"
                    for (s24 in s24Adj) print s24Adj[s24], s24, "24"
                    for (s16 in s16Adj) print s16Adj[s16], s16, "16"
                }
            }'
        )

        split_at=-1
        for i in "${!chunk[@]}"; do
            if [[ "${chunk[$i]}" == "__SUMMARY__" ]]; then
                split_at=$i
                break
            fi
        done

        if [ "$split_at" -ge 0 ]; then
            if [ "$split_at" -gt 0 ]; then
                SUBNET_MON_RAW_IPS+=("${chunk[@]:0:split_at}")
            fi
            if [ "$split_at" -lt $((${#chunk[@]} - 1)) ]; then
                SUBNET_MON_SUMMARY_LINES+=("${chunk[@]:$((split_at + 1))}")
            fi
        fi
    done

    build_agg_maps_from_summary_lines
    SUBNET_MON_WINDOW_LOADED=1
}

# Re-aggregate only from SUBNET_MON_RAW_IPS (the log is not read from disk).
# Useful after changing BLOCK_MODE / thresholds if the cache is already loaded.
recompute_summary_lines_from_raw() {
    SUBNET_MON_SUMMARY_LINES=()
    [ ${#SUBNET_MON_RAW_IPS[@]} -eq 0 ] && { build_agg_maps_from_summary_lines; return 0; }

    local agg
    agg=$(
        printf '%s\n' "${SUBNET_MON_RAW_IPS[@]}" | awk \
            -v block_mode="$BLOCK_MODE" \
            -v thip="$THRESHOLDIP" \
            -v th24="$THRESHOLD24" \
            -v th16="$THRESHOLD16" '
        function ip2sub24(ip,    o) {
            split(ip, o, ".")
            return o[1]"."o[2]"."o[3]".0/24"
        }
        function ip2sub16(ip,    o) {
            split(ip, o, ".")
            return o[1]"."o[2]".0.0/16"
        }
        function sub24_to_sub16(sub24,    p, o) {
            split(sub24, p, "/")
            split(p[1], o, ".")
            return o[1]"."o[2]".0.0/16"
        }

        /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
            ip = $0
            s24 = ip2sub24(ip)
            s16 = ip2sub16(ip)
            ipC[ip]++
            s24C[s24]++
            s16C[s16]++
        }

        END {
            for (s in s24C) s24Adj[s] = s24C[s]
            for (s in s16C) s16Adj[s] = s16C[s]

            if (block_mode == "ip" || block_mode == "all" || block_mode == "both") {
                for (ip in ipC) {
                    if (ipC[ip] > thip) {
                        s24 = ip2sub24(ip)
                        s16 = ip2sub16(ip)
                        s24Adj[s24] -= ipC[ip]
                        if (s24Adj[s24] < 0) s24Adj[s24] = 0
                        s16Adj[s16] -= ipC[ip]
                        if (s16Adj[s16] < 0) s16Adj[s16] = 0
                    }
                }
            }

            if (block_mode == "all" || block_mode == "both") {
                for (s24 in s24Adj) {
                    if (s24Adj[s24] > th24) {
                        s16 = sub24_to_sub16(s24)
                        s16Adj[s16] -= s24Adj[s24]
                        if (s16Adj[s16] < 0) s16Adj[s16] = 0
                    }
                }
            }

            if (block_mode == "ip") {
                for (ip in ipC) print ipC[ip], ip, "ip"
            } else if (block_mode == "24only") {
                for (s24 in s24C) print s24C[s24], s24, "24"
            } else if (block_mode == "16only") {
                for (s16 in s16C) print s16C[s16], s16, "16"
            } else {
                for (ip in ipC) print ipC[ip], ip, "ip"
                for (s24 in s24Adj) print s24Adj[s24], s24, "24"
                for (s16 in s16Adj) print s16Adj[s16], s16, "16"
            }
        }'
    )
    if [ -n "$agg" ]; then
        mapfile -t SUBNET_MON_SUMMARY_LINES <<< "$agg"
    else
        SUBNET_MON_SUMMARY_LINES=()
    fi
    build_agg_maps_from_summary_lines
}

# Per-request expansion (like the old count_requests_last_window) — memory only, after load_access_log_window_cache
count_requests_last_window() {
    [ ${#SUBNET_MON_RAW_IPS[@]} -eq 0 ] && return 0
    printf '%s\n' "${SUBNET_MON_RAW_IPS[@]}" | awk -v block_mode="$BLOCK_MODE" '
    {
        ip = $0
        if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) next
        split(ip, o, ".")
        subnet24 = o[1]"."o[2]"."o[3]".0/24"
        subnet16 = o[1]"."o[2]".0.0/16"
        if (block_mode == "ip") {
            print ip " ip"
        } else if (block_mode == "16only") {
            print subnet16 " 16"
        } else if (block_mode == "24only") {
            print subnet24 " 24"
        } else {
            print ip " ip"
            print subnet24 " 24"
            print subnet16 " 16"
        }
    }'
}

# Print the summary (like the old summarize_requests_last_window) — from the in-memory cache only
summarize_requests_last_window() {
    local line
    for line in "${SUBNET_MON_SUMMARY_LINES[@]}"; do
        printf '%s\n' "$line"
    done
}

# ================== MODES ==================

monitor_subnets() {
    local mon_ts
    mon_ts=$(date)
    case "$BLOCK_MODE" in
        24only) echo "$mon_ts: Monitoring /24 only (BLOCK_MODE=$BLOCK_MODE), last ${LOG_WINDOW_SECONDS} s..." ;;
        16only) echo "$mon_ts: Monitoring /16 only (BLOCK_MODE=$BLOCK_MODE), last ${LOG_WINDOW_SECONDS} s..." ;;
        ip)     echo "$mon_ts: Monitoring IPs (BLOCK_MODE=$BLOCK_MODE), last ${LOG_WINDOW_SECONDS} s..." ;;
        *)      echo "$mon_ts: Monitoring IP + /24 + /16 (BLOCK_MODE=${BLOCK_MODE:-all}), last ${LOG_WINDOW_SECONDS} s..." ;;
    esac
    echo "Log window: last ${LOG_WINDOW_SECONDS} s before the last access-log record (not the duration of this output)."
    refresh_whitelist_cache
    refresh_iptables_cache
    echo "Whitelist loaded: ${#SUBNET_MON_WHITELIST_ITEMS[@]} rules"

    while read -r count subnet mask; do
        [ -z "$count" ] || [ -z "$subnet" ] || [ -z "$mask" ] && continue

        if is_subnet_in_whitelist "$subnet"; then
            echo "$mon_ts: WHITELIST $mask: $subnet - $count requests/${LOG_WINDOW_SECONDS}s"
            continue
        fi

        if [ "$mask" = "ip" ] && [ "$count" -gt "$THRESHOLDIP" ]; then
            if ! is_ip_banned "$subnet"; then
                echo "$(date): THRESHOLD IP: $subnet - $count requests/${LOG_WINDOW_SECONDS}s"
                ban_ip "$subnet" "$count"
            fi
        elif [ "$mask" = "24" ] && [ "$count" -gt "$THRESHOLD24" ]; then
            if ! is_subnet_banned "$subnet"; then
                echo "$(date): THRESHOLD /24: $subnet - $count requests/${LOG_WINDOW_SECONDS}s"
                ban_subnet "$subnet" "$count" "$mask"
            fi
        elif [ "$mask" = "16" ] && [ "$count" -gt "$THRESHOLD16" ]; then
            if ! is_subnet_banned "$subnet"; then
                echo "$(date): THRESHOLD /16: $subnet - $count requests/${LOG_WINDOW_SECONDS}s"
                ban_subnet "$subnet" "$count" "$mask"
            fi
        else
            echo "$mon_ts: OK $subnet ($mask) - $count requests/${LOG_WINDOW_SECONDS}s"
        fi
    done < <(summarize_requests_last_window | sort -nr)
}

quick_monitor() {
    # First count the log and ban; unban by timer afterwards (otherwise the log may be truncated and history lost before the ban)
    refresh_whitelist_cache
    refresh_iptables_cache
    while read -r count subnet mask; do
        # Skip the whitelist
        is_subnet_in_whitelist "$subnet" && continue

        # Block if not already banned
        if [ "$mask" = "ip" ]; then
            if [ "$count" -gt "$THRESHOLDIP" ] && ! is_ip_banned "$subnet"; then
                ban_ip "$subnet" "$count"
            fi
        else
            if [ "$mask" = "24" ]; then
                if [ "$count" -gt "$THRESHOLD24" ] && ! is_subnet_banned "$subnet"; then
                    ban_subnet "$subnet" "$count" "$mask"
                fi
            elif [ "$mask" = "16" ]; then
                if [ "$count" -gt "$THRESHOLD16" ] && ! is_subnet_banned "$subnet"; then
                    ban_subnet "$subnet" "$count" "$mask"
                fi
            fi
        fi
    done < <(summarize_requests_last_window)

    unban_old_subnets
}


# Show banned subnets
show_banned() {
    echo "=== BANNED SUBNETS IN IPTABLES ==="

    # One chain snapshot: otherwise pkts/bytes grow between calls (DROP is a live stream).
    local _ipt_save
    _ipt_save=$(sudo iptables -L "$IPTABLES_CHAIN" -n -v --line-numbers 2>/dev/null) || _ipt_save=""

    # Show iptables rules
    echo ""
    echo "Rules in chain $IPTABLES_CHAIN:"
    while IFS= read -r line; do
        [[ "$line" =~ (DROP|REJECT) ]] && echo "  $line"
    done <<< "$_ipt_save"

    echo ""
    echo "=== SUBNETS /24 ==="
    # With --line-numbers: $1=num, $2=pkts, $3=bytes, $4=target (DROP/REJECT).
    awk '
        ($4 == "DROP" || $4 == "REJECT") && $0 ~ /\/24/ {
            pkts = $2; bytes = $3
            for (i = 1; i <= NF; i++)
                if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/24$/)
                    { print "  Subnet: " $i " | Packets: " pkts " | Bytes: " bytes; next }
        }' <<< "$_ipt_save"

    echo ""
    echo "=== SUBNETS /16 ==="
    awk '
        ($4 == "DROP" || $4 == "REJECT") && $0 ~ /\/16/ {
            pkts = $2; bytes = $3
            for (i = 1; i <= NF; i++)
                if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/16$/)
                    { print "  Subnet: " $i " | Packets: " pkts " | Bytes: " bytes; next }
        }' <<< "$_ipt_save"

    echo ""
    echo "=== IP ==="
    awk '
        ($4 == "DROP" || $4 == "REJECT") && $0 !~ /\/(24|16)/ {
            pkts = $2; bytes = $3
            for (i = 1; i <= NF; i++)
                if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)
                    { print "  IP: " $i " | Packets: " pkts " | Bytes: " bytes; next }
        }' <<< "$_ipt_save"

    # Show information from the ban file
    if [ -f "$BAN_FILE" ] && [ -s "$BAN_FILE" ]; then
        echo ""
        echo "=== BAN FILE INFO ($BAN_FILE) ==="
        echo "Total records: $(wc -l < "$BAN_FILE")"
        echo ""

        local current_time=$(date +%s)
        echo "Subnet ban times:"
        while IFS= read -r line; do
            [ -z "$line" ] && continue

            local ban_time=$(echo "$line" | awk '{print $1}')
            local subnet=$(echo "$line" | awk '{print $2}')
            local mask=$(echo "$line" | awk '{print $3}')

            if [[ "$ban_time" =~ ^[0-9]+$ ]]; then
                local time_passed=$((current_time - ban_time))
                local time_left=$((BAN_TIME - time_passed))

                if [ "$time_left" -gt 0 ]; then
                    local hours=$((time_left / 3600))
                    local minutes=$(((time_left % 3600) / 60))
                    local seconds=$((time_left % 60))

                    printf "  %-20s | Banned: %s | Unban in: " "$subnet" "$(date -d "@$ban_time" '+%H:%M:%S')"

                    if [ $hours -gt 0 ]; then
                        printf "%dh %dm %ds\n" $hours $minutes $seconds
                    elif [ $minutes -gt 0 ]; then
                        printf "%dm %ds\n" $minutes $seconds
                    else
                        printf "%ds\n" $seconds
                    fi
                else
                    printf "  %-20s | Banned: %s | TIME EXPIRED (needs unban)\n" "$subnet" "$(date -d "@$ban_time" '+%H:%M:%S')"
                fi
            fi
        done < "$BAN_FILE"
    else
        echo ""
        echo "=== BAN FILE ==="
        echo "File $BAN_FILE does not exist or is empty"
    fi

    # Stats (from the same snapshot as the blocks above)
    echo ""
    echo "=== STATS ==="
    local total_banned_24 total_banned_16 total_banned_ip
    total_banned_24=$(grep -cE "DROP.*/24|REJECT.*/24" <<< "$_ipt_save" 2>/dev/null || true)
    total_banned_16=$(grep -cE "DROP.*/16|REJECT.*/16" <<< "$_ipt_save" 2>/dev/null || true)
    total_banned_ip=$(grep -E "DROP|REJECT" <<< "$_ipt_save" 2>/dev/null | grep -vcE "/(24|16)" || true)
    echo "Total banned /24 subnets: $total_banned_24"
    echo "Total banned /16 subnets: $total_banned_16"
    echo "Total banned IPs: $total_banned_ip"
    echo "Total iptables rules: $((total_banned_24 + total_banned_16 + total_banned_ip))"

    if [ -f "$BAN_FILE" ] && [ -s "$BAN_FILE" ]; then
        local file_count_24
        local file_count_16
        local file_count_ip
        # In BAN_FILE the mask is the third field: "24", "16", "ip" (not "/24" at the end of the line)
        file_count_24=$(grep -cE '[[:space:]]24$' "$BAN_FILE" 2>/dev/null || true)
        file_count_16=$(grep -cE '[[:space:]]16$' "$BAN_FILE" 2>/dev/null || true)
        file_count_ip=$(grep -cE '[[:space:]]ip$' "$BAN_FILE" 2>/dev/null || true)
        echo "Ban-file records /24: $file_count_24"
        echo "Ban-file records /16: $file_count_16"
        echo "Ban-file records IP: $file_count_ip"
    fi
}

# Function to truncate access logs (safety; not called automatically now)
clear_access_logs() {
    for log_file in $LOG_FILES; do
        if [ -f "$log_file" ]; then
            if ! : > "$log_file" 2>/dev/null; then
                echo "  Warning: failed to truncate $log_file (permissions?)"
            fi
        fi
    done
}

# Clear all bans
clear_all_bans() {
    echo "Clearing all subnet bans..."

    local deleted_rules=0

    # Remove:
    # 1) All rules with our comment (new script versions)
    # 2) Legacy: DROP for IPv4 and IPv4/(24|16) (old versions without a comment)
    #
    # Important: use -v so the format is stable:
    # num pkts bytes target prot opt in out source destination [comment...]
    rules=$(
        sudo iptables -L "$IPTABLES_CHAIN" --line-numbers -n -v 2>/dev/null | awk '
        $4 == "DROP" {
            src = $9
            line = $0
            if (line ~ /subnet-monitor/) { print line; next }
            if (src ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/(24|16)$/) { print line; next }
            if (src ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print line; next }
        }' | tac
    )

    while read line; do
        [ -z "$line" ] && continue
        rule_num=$(echo "$line" | awk '{print $1}')
        subnet=$(echo "$line" | awk '{print $9}')
        echo "  Removing rule #$rule_num for $subnet"
        if sudo iptables -D "$IPTABLES_CHAIN" "$rule_num" 2>/dev/null; then
            deleted_rules=$((deleted_rules + 1))
        fi
    done <<< "$rules"

    > "$BAN_FILE"
    echo "  iptables rules removed: $deleted_rules — access logs are NOT touched"

    echo "All bans cleared"
}

# Test function (only the last LOG_WINDOW_SECONDS seconds)
test_recent_requests() {
    local window="${LOG_WINDOW_SECONDS:-60}"
    local time_ago=$(get_time_ago "$window")

    echo "$(date): TEST - requests in the last ${window} seconds (since $time_ago)"
    echo "Thresholds: IP > $THRESHOLDIP, /24 > $THRESHOLD24, /16 > $THRESHOLD16"
    echo ""

    # Collect stats
    summarize_requests_last_window | awk '
    $3 == "ip" { ip[$2] = $1 }
    $3 == "24" { s24[$2] = $1 }
    $3 == "16" { s16[$2] = $1 }
    END {
        print "=== IPs (active) ==="
        for (k in ip) if (ip[k] > 10) print ip[k], k
        print ""
        print "=== SUBNETS /24 (active) ==="
        for (k in s24) if (s24[k] > 10) print s24[k], k
        print ""
        print "=== SUBNETS /16 (active) ==="
        for (k in s16) if (s16[k] > 30) print s16[k], k
    }' | while read count subnet; do
        [ -n "$count" ] && [ -n "$subnet" ] && echo "  $count - $subnet"
    done

    # Overall stats
    totals=$(summarize_requests_last_window | awk '
    $3 == "ip" { totalip += $1 }
    $3 == "24" { total24 += $1 }
    $3 == "16" { total16 += $1 }
    END {
        print "Requests by IP: " totalip
        print "Requests in /24 subnets: " total24
        print "Requests in /16 subnets: " total16
    }')

    echo ""
    echo "$totals"

    # Show the whitelist
    echo ""
    echo "=== WHITELIST ==="
    local whitelist_count=$(load_whitelist | wc -w)
    echo "Whitelist rules: $whitelist_count"
    if [ "$whitelist_count" -gt 0 ]; then
        load_whitelist | tr ' ' '\n' | while read item; do
            echo "  $item"
        done
    fi
}


# ================== MAIN MENU ==================

main() {
    # Create required files
    [ -f "$BAN_LOG" ] || touch "$BAN_LOG"
    [ -f "$UNBAN_LOG" ] || touch "$UNBAN_LOG"
    [ -f "$DEBUG_LOG" ] || touch "$DEBUG_LOG"
    [ -f "$BAN_FILE" ] || touch "$BAN_FILE"

    # validate_access_logs_format — filters LOG_FILES; then monitor/ban from the log; unban by BAN_TIME afterwards.
    # show and clear skip the log filter; show still unbans before printing.
    case "$1" in
        "monitor")
            validate_access_logs_format
            load_access_log_window_cache
            monitor_subnets
            unban_old_subnets
            ;;
        "run")
            validate_access_logs_format
            load_access_log_window_cache
            quick_monitor
            ;;
        "test")
            validate_access_logs_format
            load_access_log_window_cache
            test_recent_requests
            ;;
        "show")
            unban_old_subnets
            show_banned
            ;;
        "clear")
            clear_all_bans
            ;;
        *)
            echo "Usage: $0 {monitor|run|test|show|clear}"
            exit 1
            ;;
    esac
}

# Run
main "$1" "$2"