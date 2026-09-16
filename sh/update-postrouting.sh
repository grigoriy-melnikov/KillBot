#!/bin/bash

set -euo pipefail

TARGET_FILE="/opt/killbot/postrouting.txt"
SET_NAME="proxy_targets"
CHAIN_NAME="KB_POSTROUTING_ROTATE"
SYMMETRIC_CHAIN="KB_SYMMETRIC_SNAT"
OUT_PORT=443

log() {
    echo "[$(date '+%F %T')] $*"
}

place_nat_postrouting_jump() {
    local chain="$1"
    local after_chain="${2:-}"

    while iptables -t nat -C POSTROUTING -j "$chain" 2>/dev/null; do
        iptables -t nat -D POSTROUTING -j "$chain" 2>/dev/null || true
    done

    if [ -n "$after_chain" ] && iptables -t nat -C POSTROUTING -j "$after_chain" 2>/dev/null; then
        local pos
        pos=$(iptables -t nat -L POSTROUTING --line-numbers -n |
            awk -v target="$after_chain" '$2 == target {print $1; exit}')
        if [ -n "$pos" ]; then
            iptables -t nat -I POSTROUTING "$((pos + 1))" -j "$chain"
            return
        fi
    fi

    iptables -t nat -A POSTROUTING -j "$chain"
}

disable_rotation() {
    log "Disabling KillBot SNAT rotation..."

    iptables -t nat -F "$CHAIN_NAME" 2>/dev/null || true

    while iptables -t nat -C POSTROUTING -j "$CHAIN_NAME" 2>/dev/null; do
        iptables -t nat -D POSTROUTING -j "$CHAIN_NAME" 2>/dev/null || true
    done

    iptables -t nat -X "$CHAIN_NAME" 2>/dev/null || true

    ipset destroy "$SET_NAME" 2>/dev/null || true
    ipset destroy "${SET_NAME}_tmp" 2>/dev/null || true

    log "KillBot SNAT rotation disabled."
}

###########################################
# File check
###########################################

if [ ! -f "$TARGET_FILE" ]; then
    disable_rotation
    log "File $TARGET_FILE does not exist. Rotation disabled."
    exit 0
fi

if [ ! -s "$TARGET_FILE" ]; then
    disable_rotation
    log "File $TARGET_FILE is empty. Rotation disabled."
    exit 0
fi

NOW=$(date +%s)
MTIME=$(stat -c %Y "$TARGET_FILE")
AGE=$((NOW-MTIME))

if [ "$AGE" -gt 300 ]; then
    log "File is older than 5 minutes ($AGE sec). Nothing to do."
    exit 0
fi

###########################################
# iptables chain
###########################################

iptables -t nat -N "$CHAIN_NAME" 2>/dev/null || true
place_nat_postrouting_jump "$CHAIN_NAME" "$SYMMETRIC_CHAIN"
iptables -t nat -F "$CHAIN_NAME"

###########################################
# Get public IPs
###########################################

mapfile -t SERVER_IPS < <(
ip -4 addr show scope global |
awk '/inet /{print $2}' |
cut -d/ -f1 |
grep -Ev '^(10\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' |
sort -u
)

if [ "${#SERVER_IPS[@]}" -le 1 ]; then
    log "Only one public IP found (${SERVER_IPS[*]}). Rotation is not needed."
    exit 0
fi

log "External server IPs found: ${#SERVER_IPS[@]}"
for ip in "${SERVER_IPS[@]}"; do
    log "  Source IP: $ip"
done

###########################################
# Create the ipset
###########################################

TMP_SET="${SET_NAME}_tmp"

ipset destroy "$TMP_SET" 2>/dev/null || true
ipset create "$TMP_SET" hash:ip family inet

TARGET_COUNT=0

while read -r line; do

    ip=$(echo "$line" | sed 's/#.*//' | xargs)

    [ -z "$ip" ] && continue

    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        ipset add "$TMP_SET" "$ip" -exist
        ((TARGET_COUNT+=1))
    fi

done < "$TARGET_FILE"

if [ "$TARGET_COUNT" -eq 0 ]; then
    ipset destroy "$TMP_SET"
    log "No valid IPs in the file. Rotation disabled."
    exit 0
fi

ipset create "$SET_NAME" hash:ip family inet 2>/dev/null || true
ipset swap "$TMP_SET" "$SET_NAME"
ipset destroy "$TMP_SET"

log "IPSet '$SET_NAME' contains $TARGET_COUNT IPs."

###########################################
# Create SNAT rules
###########################################

COUNT=${#SERVER_IPS[@]}

for i in "${!SERVER_IPS[@]}"; do

    SRC_IP="${SERVER_IPS[$i]}"
    REMAINING=$((COUNT-i))

    if [ "$REMAINING" -eq 1 ]; then

        iptables -t nat -A "$CHAIN_NAME" \
            -p tcp \
            -m set --match-set "$SET_NAME" dst \
            --dport "$OUT_PORT" \
            -j SNAT --to-source "$SRC_IP"

        log "Added rule: all remaining -> $SRC_IP"

    else

        PROB=$(awk -v r="$REMAINING" 'BEGIN{printf "%.10f",1/r}')

        iptables -t nat -A "$CHAIN_NAME" \
            -p tcp \
            -m set --match-set "$SET_NAME" dst \
            --dport "$OUT_PORT" \
            -m statistic --mode random --probability "$PROB" \
            -j SNAT --to-source "$SRC_IP"

        log "Added rule: probability $PROB -> $SRC_IP"

    fi

done

log "---------------------------------------------"
log "Rotation enabled successfully."
log "POSTROUTING order: $SYMMETRIC_CHAIN (if present) -> $CHAIN_NAME"
log "Destination IPs: $TARGET_COUNT"
log "Outbound IPs: ${#SERVER_IPS[@]}"
log "Chain: $CHAIN_NAME"
log "IPSet: $SET_NAME"
log "---------------------------------------------"

