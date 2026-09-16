#!/bin/bash

set -euo pipefail

STATE_FILE="/opt/killbot/symmetric-ip.state"
CHAIN_MARK="KB_SYMMETRIC_MARK"
CHAIN_OUTPUT="KB_SYMMETRIC_OUT"
CHAIN_SNAT="KB_SYMMETRIC_SNAT"
ROTATE_CHAIN="KB_POSTROUTING_ROTATE"
PROXY_SET="proxy_targets"
MARK_BASE=100
TABLE_BASE=200
RULE_PRIORITY=1000

log() {
    echo "[$(date '+%F %T')] $*"
}

place_nat_postrouting_jump() {
    local chain="$1"
    local mode="${2:-append}"

    while iptables -t nat -C POSTROUTING -j "$chain" 2>/dev/null; do
        iptables -t nat -D POSTROUTING -j "$chain" 2>/dev/null || true
    done

    if [ "$mode" = "first" ]; then
        iptables -t nat -I POSTROUTING 1 -j "$chain"
        return
    fi

    if [ -n "$mode" ] && iptables -t nat -C POSTROUTING -j "$mode" 2>/dev/null; then
        local pos
        pos=$(iptables -t nat -L POSTROUTING --line-numbers -n |
            awk -v target="$mode" '$2 == target {print $1; exit}')
        if [ -n "$pos" ]; then
            iptables -t nat -I POSTROUTING "$((pos + 1))" -j "$chain"
            return
        fi
    fi

    iptables -t nat -A POSTROUTING -j "$chain"
}

add_symmetric_snat_rule() {
    local mark="$1"
    local ip="$2"

    if ipset list "$PROXY_SET" &>/dev/null; then
        iptables -t nat -A "$CHAIN_SNAT" \
            -m connmark --mark "$mark" \
            -m set ! --match-set "$PROXY_SET" dst \
            -m addrtype ! --dst-type LOCAL \
            -j SNAT --to-source "$ip"
    else
        iptables -t nat -A "$CHAIN_SNAT" \
            -m connmark --mark "$mark" \
            -m addrtype ! --dst-type LOCAL \
            -j SNAT --to-source "$ip"
    fi
}

get_server_ips() {
    ip -4 addr show scope global |
        awk '/inet /{print $2}' |
        cut -d/ -f1 |
        grep -Ev '^(10\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' |
        sort -u
}

disable_symmetric_ip() {
    log "Disabling KillBot symmetric SNAT..."

    iptables -t nat -F "$CHAIN_SNAT" 2>/dev/null || true
    while iptables -t nat -C POSTROUTING -j "$CHAIN_SNAT" 2>/dev/null; do
        iptables -t nat -D POSTROUTING -j "$CHAIN_SNAT" 2>/dev/null || true
    done
    iptables -t nat -X "$CHAIN_SNAT" 2>/dev/null || true

    iptables -t mangle -F "$CHAIN_MARK" 2>/dev/null || true
    while iptables -t mangle -C PREROUTING -j "$CHAIN_MARK" 2>/dev/null; do
        iptables -t mangle -D PREROUTING -j "$CHAIN_MARK" 2>/dev/null || true
    done
    iptables -t mangle -X "$CHAIN_MARK" 2>/dev/null || true

    iptables -t mangle -F "$CHAIN_OUTPUT" 2>/dev/null || true
    while iptables -t mangle -C OUTPUT -j "$CHAIN_OUTPUT" 2>/dev/null; do
        iptables -t mangle -D OUTPUT -j "$CHAIN_OUTPUT" 2>/dev/null || true
    done
    iptables -t mangle -X "$CHAIN_OUTPUT" 2>/dev/null || true

    if [ -f "$STATE_FILE" ]; then
        while read -r ip table_id _mark; do
            [ -z "$ip" ] && continue
            ip rule del from "$ip" table "$table_id" priority "$RULE_PRIORITY" 2>/dev/null || true
            ip rule del from "$ip" table "$table_id" 2>/dev/null || true
            ip route flush table "$table_id" 2>/dev/null || true
        done < "$STATE_FILE"
        rm -f "$STATE_FILE"
    fi

    log "KillBot symmetric SNAT disabled."
}

###########################################
# Get the server public IPs
###########################################

mapfile -t SERVER_IPS < <(get_server_ips)

if [ "${#SERVER_IPS[@]}" -le 1 ]; then
    disable_symmetric_ip
    if [ "${#SERVER_IPS[@]}" -eq 0 ]; then
        log "No public IPv4 addresses found. No rules needed."
    else
        log "Only one public IP found (${SERVER_IPS[0]}). No rules needed."
    fi
    exit 0
fi

read -r DEFAULT_GW DEFAULT_IFACE < <(ip -4 route show default | awk 'NR==1 {print $3, $5}')
if [ -z "${DEFAULT_GW:-}" ] || [ -z "${DEFAULT_IFACE:-}" ]; then
    log "ERROR: failed to detect the default gateway/interface."
    exit 1
fi

###########################################
# Remove old rules and create new ones
###########################################

disable_symmetric_ip

iptables -t mangle -N "$CHAIN_MARK" 2>/dev/null || true
iptables -t mangle -N "$CHAIN_OUTPUT" 2>/dev/null || true
iptables -t nat -N "$CHAIN_SNAT" 2>/dev/null || true

iptables -t mangle -C PREROUTING -j "$CHAIN_MARK" 2>/dev/null || \
    iptables -t mangle -A PREROUTING -j "$CHAIN_MARK"

iptables -t mangle -C OUTPUT -j "$CHAIN_OUTPUT" 2>/dev/null || \
    iptables -t mangle -A OUTPUT -j "$CHAIN_OUTPUT"

place_nat_postrouting_jump "$CHAIN_SNAT" "first"
if iptables -t nat -C POSTROUTING -j "$ROTATE_CHAIN" 2>/dev/null; then
    place_nat_postrouting_jump "$ROTATE_CHAIN" "$CHAIN_SNAT"
fi

iptables -t mangle -A "$CHAIN_OUTPUT" -j CONNMARK --restore-mark

log "External server IPs found: ${#SERVER_IPS[@]}"
log "Default route: via $DEFAULT_GW dev $DEFAULT_IFACE"

: > "$STATE_FILE"

TABLE_ID=$TABLE_BASE
MARK=$MARK_BASE

for ip in "${SERVER_IPS[@]}"; do
    log "  IP: $ip (mark=$MARK, table=$TABLE_ID)"

    iptables -t mangle -A "$CHAIN_MARK" -d "$ip" -j CONNMARK --set-mark "$MARK"
    iptables -t mangle -A "$CHAIN_OUTPUT" -s "$ip" -j CONNMARK --set-mark "$MARK"

    add_symmetric_snat_rule "$MARK" "$ip"

    ip rule del from "$ip" table "$TABLE_ID" priority "$RULE_PRIORITY" 2>/dev/null || true
    ip rule del from "$ip" table "$TABLE_ID" 2>/dev/null || true
    ip rule add from "$ip" table "$TABLE_ID" priority "$RULE_PRIORITY"
    ip route replace default via "$DEFAULT_GW" dev "$DEFAULT_IFACE" src "$ip" table "$TABLE_ID"

    echo "$ip $TABLE_ID $MARK" >> "$STATE_FILE"

    ((TABLE_ID+=1))
    ((MARK+=1))
done

log "---------------------------------------------"
log "Symmetric SNAT enabled."
log "Inbound server IP = outbound IP for the rest of the traffic."
log "Exception: dst from ipset $PROXY_SET is handled by $ROTATE_CHAIN."
log "POSTROUTING order: $CHAIN_SNAT -> $ROTATE_CHAIN (if present)"
log "Chains: $CHAIN_MARK, $CHAIN_OUTPUT, $CHAIN_SNAT"
log "State: $STATE_FILE"
log "---------------------------------------------"
