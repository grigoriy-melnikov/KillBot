#!/bin/bash
set -e

CONFIG="/opt/killbot/f2b/block_all_countries_except.config"
IPSET_NAME="country-whitelist"
TMP_DIR="/tmp/ipdeny"

mkdir -p "$TMP_DIR"

source "$CONFIG"

echo "[*] Countries: $COUNTRIES"
echo "[*] Ports: $PORTS"

apt install -y ipset iptables wget >/dev/null

ipset destroy "$IPSET_NAME" 2>/dev/null || true
ipset create "$IPSET_NAME" hash:net

IFS=',' read -ra COUNTRY_LIST <<< "$COUNTRIES"

for COUNTRY in "${COUNTRY_LIST[@]}"; do
    COUNTRY="$(echo "$COUNTRY" | tr '[:upper:]' '[:lower:]' | xargs)"
    ZONE_FILE="$TMP_DIR/$COUNTRY.zone"

    echo "[*] Download $COUNTRY"
    wget -q -O "$ZONE_FILE" "http://www.ipdeny.com/ipblocks/data/countries/$COUNTRY.zone"

    while read -r NET; do
        [ -n "$NET" ] && ipset add "$IPSET_NAME" "$NET" 2>/dev/null || true
    done < "$ZONE_FILE"
done

echo "[*] Total networks loaded:"
ipset list "$IPSET_NAME" | grep "Number of entries"

# ---- IPTABLES ----

# Remove old rules
iptables -D INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp -m multiport --dports "$PORTS" -m set --match-set "$IPSET_NAME" src -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp -m multiport --dports "$PORTS" -j DROP 2>/dev/null || true

# Add in the correct order
iptables -I INPUT 1 -p tcp -m multiport --dports "$PORTS" -j DROP
iptables -I INPUT 1 -p tcp -m multiport --dports "$PORTS" -m set --match-set "$IPSET_NAME" src -j ACCEPT
iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo "[OK] Firewall rules applied"
iptables -L INPUT -n -v --line-numbers | head -n 20