#!/bin/bash

# Check whether nginx is installed
check_nginx() {
    if command -v nginx &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 0. Detect this server's IPv4
CURRENT_IP=$(curl -4 -s ifconfig.me || curl -4 -s icanhazip.com || curl -4 -s ipinfo.io/ip || echo "")

if [ -z "$CURRENT_IP" ]; then
    echo "❌ Error: failed to detect this server's IPv4"
    echo "Check the network connection and try again"
    exit 1
fi

echo "Current server IPv4: $CURRENT_IP"

# DNS used to check A records (Google + Yandex)
DNS_SERVERS=(
    "8.8.8.8"
    "77.88.8.8"
)

dig_domain_ipv4() {
    local domain="$1"
    local dns_server="$2"
    dig -4 +short @"${dns_server}" +time=5 +tries=2 "${domain}" A 2>/dev/null \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
}

resolve_domain_ipv4() {
    local domain="$1"
    local dns_server ips line
    local -a all_ips=()
    local -a resolved_by=()

    RESOLVE_DNS_USED=""
    DOMAIN_IPS=""

    for dns_server in "${DNS_SERVERS[@]}"; do
        ips=$(dig_domain_ipv4 "$domain" "$dns_server")
        if [ -n "$ips" ]; then
            resolved_by+=("$dns_server")
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                all_ips+=("$line")
            done <<< "$ips"
        fi
    done

    # unique IPs, keep order
    local -a unique_ips=()
    local ip seen
    for ip in "${all_ips[@]}"; do
        seen=false
        for u in "${unique_ips[@]}"; do
            if [ "$u" = "$ip" ]; then
                seen=true
                break
            fi
        done
        if [ "$seen" = false ]; then
            unique_ips+=("$ip")
        fi
    done

    RESOLVE_DNS_USED=$(IFS=','; echo "${resolved_by[*]}")
    if [ ${#unique_ips[@]} -gt 0 ]; then
        DOMAIN_IPS=$(printf '%s\n' "${unique_ips[@]}")
    fi
}

# 1. Domains from nginx sites-enabled/{domain.ru}.conf and /etc/letsencrypt/live/* (no duplicates)
#    Skip default, IP names and internal 000-*
DOMAINS=$(
  {
    for f in /etc/nginx/sites-enabled/*.conf; do
      [ -e "$f" ] || continue
      name=$(basename "$f" .conf)
      if [ "$name" = "default" ]; then
        continue
      fi
      if echo "$name" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        continue
      fi
      if echo "$name" | grep -Eq '^000'; then
        continue
      fi
      echo "$name"
    done
    for d in /etc/letsencrypt/live/*/; do
      [ -e "$d" ] || continue
      name=$(basename "$d")
      if echo "$name" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        continue
      fi
      if echo "$name" | grep -Eq '^000'; then
        continue
      fi
      echo "$name"
    done
  } | sort -u
)
echo "Domains found: $(echo "$DOMAINS" | grep -c . || true)"

#also print the domain list for debugging
#echo "Debug domain list: $DOMAINS"
#exit 1;

# 2-3. Check each domain
for domain in $DOMAINS; do
    resolve_domain_ipv4 "$domain"
    
    # Check whether CURRENT_IP is among all A records
    IP_FOUND=false
    if [ -n "$DOMAIN_IPS" ]; then
        while IFS= read -r ip; do
            if [ "$ip" == "$CURRENT_IP" ]; then
                IP_FOUND=true
                break
            fi
        done <<< "$DOMAIN_IPS"
    fi

    if [ -z "$DOMAIN_IPS" ]; then
        echo "  ❌ Failed to resolve domain $domain (IPv4) via DNS: ${DNS_SERVERS[*]}"
        ACTION="delete (does not resolve)"
    elif [ "$IP_FOUND" == true ]; then
        echo "  ✅ Domain $domain has an A record pointing to this server ($CURRENT_IP)"
        echo "     DNS: ${RESOLVE_DNS_USED:-—}"
        if [ $(echo "$DOMAIN_IPS" | wc -l) -gt 1 ]; then
            echo "     Other IPs: $(echo "$DOMAIN_IPS" | grep -v "$CURRENT_IP" | tr '\n' ' ')"
        fi
        ACTION="keep"
    else
        echo "  ❌ Domain $domain has no A records pointing to this server"
        echo "     DNS: ${RESOLVE_DNS_USED:-—}"
        echo "     Its IPs: $(echo "$DOMAIN_IPS" | tr '\n' ' ')"
        ACTION="delete"
    fi

    # Delete the certificate if needed
    if [[ "$ACTION" == "delete"* ]]; then
        #/opt/killbot/cert_delete.sh "$domain" do_not_reload do_not_remove_ssl_path
        /opt/killbot/cert_delete.sh "$domain" do_not_reload
    fi
done

if apache2ctl configtest >/dev/null 2>&1; then
    sudo systemctl reload apache2
else
    echo "[ERROR] Apache config invalid; skip reload. Run: apache2ctl configtest" >&2
    sudo apache2ctl configtest >&2 || true
fi
if check_nginx; then
    sudo systemctl reload nginx
fi
