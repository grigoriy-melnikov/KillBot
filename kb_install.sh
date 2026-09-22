#!/bin/bash
#yes '' | sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a ./kb_install.sh

export DEBIAN_FRONTEND=noninteractive

#ServerLimit 64
MAX_CONNECTIONS=5000

#MaxRequestWorkers 4096
MAX_CONNECTIONS_WORKERS=5000

KILLBOT_ACCOUNT_TOKEN="p6CmXezQY"

# Maximum number of simultaneous connections for bots
MAX_CONNECTIONS_BOTS=50

# Maximum number of simultaneous connections from a single IP to the verification page
MAX_CONNECTIONS_IP_VP=20

MAX_OPEN_FILES=1000000
MAX_OPEN_FILES_SYS=3000000
MAX_PROCESSES=20000
KILLBOT_SESSION_LIFETIME=86400 #sec

set -e # Exit immediately if any command fails

KB_GIT_RAW="https://raw.githubusercontent.com/grigoriy-melnikov/KillBot/main"

kb_download() {
  local dest="$1"
  local path="$2"
  timeout 15 curl --connect-timeout 10 -f -L -o "$dest" "${KB_GIT_RAW}/${path}"
}


sudo apt update

rm -rf /var/log/apache2/*
rm -rf /var/log/killbot/*

# flush iptables if any subnets were blocked
if [ -f /opt/killbot/f2b/subnet-monitor.sh ]; then
  chmod +x /opt/killbot/f2b/subnet-monitor.sh 2>/dev/null || true
  bash /opt/killbot/f2b/subnet-monitor.sh clear || true
fi

# unblock traffic if anything is still blocked
if [ -f /opt/killbot/f2b/unblock_traffic.sh ]; then
  chmod +x /opt/killbot/f2b/unblock_traffic.sh 2>/dev/null || true
  bash /opt/killbot/f2b/unblock_traffic.sh || true
fi

sudo apt install needrestart

# Path to the configuration file
CONFIG_FILE="/etc/needrestart/needrestart.conf"

# Check whether the file exists
if [ -f "$CONFIG_FILE" ]; then
    # Make a backup (just in case)
    sudo cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
    
    # Check whether a $nrconf{restart} line exists
    if grep -q '^\s*$nrconf{restart}' "$CONFIG_FILE"; then
        # If present — replace it (commented or active)
        sudo sed -i 's/^\s*$nrconf{restart}.*/$nrconf{restart} = '"'a'"';/' "$CONFIG_FILE"
        echo "$nrconf{restart} line updated to '$nrconf{restart} = 'a';'"
    else
        # If missing — append at the end
        echo '$nrconf{restart} = '\''a'\'';' | sudo tee -a "$CONFIG_FILE" > /dev/null
        echo "$nrconf{restart} = 'a' appended at the end of the file"
    fi
else
    # If the file is missing — create it with the required line
    echo '$nrconf{restart} = '\''a'\'';' | sudo tee "$CONFIG_FILE" > /dev/null
    echo "File $CONFIG_FILE created with the required setting"
fi

sudo apt install lsb-release -y

sudo apt install -y socat curl


CURRENT_SERVER_IP=$(curl -s http://checkip.amazonaws.com)
#echo "Current server IP: $CURRENT_SERVER_IP"

#Get information about the Ubuntu version
OS_ID=$(lsb_release -is)
OS_VERSION=$(lsb_release -rs)

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run with sudo!"
    exit 1
fi

# Check that the system is Ubuntu and version is 22.04
if [[ "$OS_ID" == "Ubuntu" && ("$OS_VERSION" == "22.04") ]]; then
    echo "Running on Ubuntu $OS_VERSION is allowed."
else
    echo "Error: The script can only run on Ubuntu 22.04."
    exit 1
fi

sudo apt update -y

sudo apt install -y apache2 php libapache2-mod-php

sudo chown -R www-data:www-data /var/www/html

sudo a2enmod ssl
sudo a2enmod rewrite
sudo a2enmod proxy
sudo a2enmod proxy_http
sudo a2enmod headers
sudo a2enmod remoteip
#sudo a2dismod status
sudo apt install logrotate -y
sudo apt install libapache2-mod-security2 -y

sudo apt install cron -y
sudo systemctl enable cron
sudo systemctl start cron

#close mail service
sudo systemctl stop postfix || true
sudo systemctl disable postfix || true

sudo apt install ipset -y

sudo apt install -y nginx

sudo apt install openssl -y

rm -rf /var/log/nginx/*

NGINX_CONF="/etc/nginx/nginx.conf"
NEW_LINE="access_log /var/log/nginx/access.log;"
OLD_LINE="access_log /var/log/apache2/nginx.access.log;"

if grep -qF "$OLD_LINE" "$NGINX_CONF"; then
    echo "[*] Found access_log line. Replacing..."
    # make a backup
    cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%s)"
    # replace
    sed -i "s|$OLD_LINE|$NEW_LINE|g" "$NGINX_CONF"
    echo "[OK] Line replaced"
else
    echo "[*] Line not found, no changes needed"
fi

OLD_LINE="access_log /var/log/apache2/access-nginx.log;"

if grep -qF "$OLD_LINE" "$NGINX_CONF"; then
    echo "[*] Found access_log line. Replacing..."
    # make a backup
    cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%s)"
    # replace
    sed -i "s|$OLD_LINE|$NEW_LINE|g" "$NGINX_CONF"
    echo "[OK] Line replaced"
else
    echo "[*] Line not found, no changes needed"
fi

SUBNET_MONITOR_CONF="/opt/killbot/f2b/subnet-monitor.conf"
# In sed, * in the pattern is a regex metacharacter; grep -qF finds the line, but sed then does not match.
# Replace line-by-line by exact match (awk) so the *access*.log mask is treated literally.
OLD_LINE='LOG_FILES="/var/log/apache2/*access*.log"'
NEW_LINE='LOG_FILES="/var/log/nginx/access.log"'

if [[ -f "$SUBNET_MONITOR_CONF" ]] && grep -qF "$OLD_LINE" "$SUBNET_MONITOR_CONF"; then
    echo "[*] Found *access*.log in subnet-monitor.conf — changing to nginx.access.log"
    cp "$SUBNET_MONITOR_CONF" "${SUBNET_MONITOR_CONF}.bak.$(date +%s)"
    _sm_tmp="${SUBNET_MONITOR_CONF}.tmp.$$"
    awk -v old="$OLD_LINE" -v new="$NEW_LINE" '{ if ($0 == old) print new; else print }' "$SUBNET_MONITOR_CONF" > "$_sm_tmp" && mv "$_sm_tmp" "$SUBNET_MONITOR_CONF"
    echo "[OK] Line replaced"
else
    echo "[*] *access*.log not found in subnet-monitor.conf, no changes needed"
fi
unset _sm_tmp

OLD_LINE='LOG_FILES="/var/log/apache2/nginx.access.log"'
NEW_LINE='LOG_FILES="/var/log/nginx/access.log"'

if [[ -f "$SUBNET_MONITOR_CONF" ]] && grep -qF "$OLD_LINE" "$SUBNET_MONITOR_CONF"; then
    echo "[*] Found *access*.log in subnet-monitor.conf — changing to nginx.access.log"
    cp "$SUBNET_MONITOR_CONF" "${SUBNET_MONITOR_CONF}.bak.$(date +%s)"
    _sm_tmp="${SUBNET_MONITOR_CONF}.tmp.$$"
    awk -v old="$OLD_LINE" -v new="$NEW_LINE" '{ if ($0 == old) print new; else print }' "$SUBNET_MONITOR_CONF" > "$_sm_tmp" && mv "$_sm_tmp" "$SUBNET_MONITOR_CONF"
    echo "[OK] Line replaced"
else
    echo "[*] *access*.log not found in subnet-monitor.conf, no changes needed"
fi
unset _sm_tmp

OLD_LINE='LOG_FILES="/var/log/apache2/access-nginx.log"'
NEW_LINE='LOG_FILES="/var/log/nginx/access.log"'

if [[ -f "$SUBNET_MONITOR_CONF" ]] && grep -qF "$OLD_LINE" "$SUBNET_MONITOR_CONF"; then
    echo "[*] Found *access*.log in subnet-monitor.conf — changing to nginx.access.log"
    cp "$SUBNET_MONITOR_CONF" "${SUBNET_MONITOR_CONF}.bak.$(date +%s)"
    _sm_tmp="${SUBNET_MONITOR_CONF}.tmp.$$"
    awk -v old="$OLD_LINE" -v new="$NEW_LINE" '{ if ($0 == old) print new; else print }' "$SUBNET_MONITOR_CONF" > "$_sm_tmp" && mv "$_sm_tmp" "$SUBNET_MONITOR_CONF"
    echo "[OK] Line replaced"
else
    echo "[*] *access*.log not found in subnet-monitor.conf, no changes needed"
fi
unset _sm_tmp


NGINX_CONF="/etc/nginx/nginx.conf"

# Check for a line without combined
if grep -qE '^[[:space:]]*access_log[[:space:]]+/var/log/nginx/access\.log;[[:space:]]*$' "$NGINX_CONF"; then

    echo "Found access_log without combined. Fixing..."

    sed -i -E \
    's|^[[:space:]]*access_log[[:space:]]+/var/log/nginx/access\.log;[[:space:]]*$|    access_log /var/log/nginx/access.log combined;|g' \
    "$NGINX_CONF"

    echo "Done."

else
    echo "No changes needed."
fi



[ "$EUID" -ne 0 ] && echo "Root privileges required" && exit 1
NGINX_CONF="/etc/nginx/nginx.conf"

if ! grep -q "map \$request \$trash_request" "$NGINX_CONF"; then
    cp "$NGINX_CONF" "${NGINX_CONF}.backup"
    sed -i '/http {/a\
    map \$request \$trash_request {\
        default                                     0;\
        "~\\\\x16\\\\x03"                               1;  # SSL handshake\
        "~OPTIONS \\*"                               1;  # OPTIONS *\
        "~^[[:cntrl:]]"                             1;  # Control characters\
    }' "$NGINX_CONF"
    echo "✅ trash_request added"    
fi

# Add a directive only if it is missing
add_if_missing() {
    local search_pattern="$1"
    local line_to_add="$2"
    
    if ! grep -q "$search_pattern" "$NGINX_CONF"; then
        sed -i "/http {/a \\    $line_to_add" "$NGINX_CONF"
        echo "✅ Added: $line_to_add"
    else
        echo "⏭️  Already exists: $search_pattern"
    fi
}

replace_if_not_equal() {
    local old_string="$1"
    local new_string="$2"

    # Already replaced
    if grep -Eq "^[[:space:]]*$(printf '%s' "$new_string" | sed 's/[][\/.^$*+?|(){}]/\\&/g')[[:space:]]*$" "$NGINX_CONF"; then        
        return 0
    fi

    # Whether there is a line to replace
    if grep -Eq "^[[:space:]]*$(printf '%s' "$old_string" | sed 's/[][\/.^$*+?|(){}]/\\&/g')[[:space:]]*$" "$NGINX_CONF"; then

        local escaped_old
        local escaped_new

        escaped_old=$(printf '%s' "$old_string" | sed 's/[\/&|]/\\&/g')
        escaped_new=$(printf '%s' "$new_string" | sed 's/[\/&|]/\\&/g')

        sed -i "s|^[[:space:]]*$escaped_old[[:space:]]*$|$escaped_new|" "$NGINX_CONF"
        return 0
    fi

    # Old line is missing — not an error; the caller may add new_string via add_if_missing
    return 0
}

# Add directives
add_if_missing "server_names_hash_bucket_size" "server_names_hash_bucket_size 128;"
add_if_missing "client_max_body_size" "client_max_body_size 256M;"

#add_if_missing "zone=conn_per_ip" "limit_conn_zone \$binary_remote_addr zone=conn_per_ip:10m;"
#add_if_missing "zone=req_per_ip" "limit_req_zone \$binary_remote_addr zone=req_per_ip:10m rate=50r/s;"
#add_if_missing "limit_conn conn_per_ip" "limit_conn conn_per_ip 50;"
#add_if_missing "limit_req zone=req_per_ip" "limit_req zone=req_per_ip burst=100 nodelay;"


add_if_missing "charset" "charset off;"
add_if_missing "proxy_buffer_size" "proxy_buffer_size 128k;"
add_if_missing "proxy_buffers" "proxy_buffers 8 256k;"
#add_if_missing "proxy_busy_buffers_size" "proxy_busy_buffers_size 64k;"

add_if_missing "map_hash_bucket_size" "map_hash_bucket_size 64;"
add_if_missing "map_hash_max_size" "map_hash_max_size 4096;"
add_if_missing "server_names_hash_bucket_size" "server_names_hash_bucket_size 128;"
add_if_missing "server_names_hash_max_size" "server_names_hash_max_size 8192;"

#add_if_missing 'limit_req_status' 'limit_req_status 444;'

replace_if_not_equal 'limit_req_status 444;' 'limit_req_status 429;'
add_if_missing 'limit_req_status' 'limit_req_status 429;'

ERROR_PAGES_INC="/etc/nginx/conf.d/killbot-too-many-requests.inc"
mkdir -p "$(dirname "$ERROR_PAGES_INC")"
cat > "$ERROR_PAGES_INC" << 'EOF'
error_page 429 /too_many_requests.html;
location = /too_many_requests.html {
    internal;
    root /opt/killbot/html;
}
EOF
chmod 644 "$ERROR_PAGES_INC"
echo "✅ Created ${ERROR_PAGES_INC}"

add_if_missing 'limit_req zone=per_host' 'limit_req zone=per_host burst=200 nodelay;'
add_if_missing 'limit_req_zone "\$host"' 'limit_req_zone "\$host" zone=per_host:40m rate=500r/s;'

add_if_missing 'limit_req zone=per_url' 'limit_req zone=per_url burst=50 nodelay;'
add_if_missing 'limit_req_zone "\$host\$uri"' 'limit_req_zone "\$host\$uri" zone=per_url:10m rate=150r/m;'



replace_if_not_equal 'ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3; # Dropping SSLv3, ref: POODLE' 'ssl_protocols TLSv1.2;'      

CONF_DIR="/etc/nginx/conf.d"
CONF_FILE="${CONF_DIR}/killbot-block-params.conf"
NGINX_CONF="/etc/nginx/nginx.conf"

# 0=off, 1=on
KB_BLOCK_IF_HAS_BLOCKED_PARAM=0   # 1: a forbidden query parameter is present
KB_BLOCK_IF_NO_PARAMS=0           # 2: query string is empty
KB_BLOCK_IF_HAS_ANY_PARAM=0       # 3: any query parameter is present
KB_BLOCK_IF_NO_ALLOWED_PARAMS=0   # 4: none of the allowed parameters are present
KB_BLOCK_IF_BAD_PATH=1            # 5: URI (path) matched a forbidden prefix/pattern
KB_BLOCK_IF_BAD_HOST=0            # 6: Host is in the forbidden list

# Path list for condition 5: prefixes without domain, without query.
# Each item is a literal prefix; the map will compile it as ^/iemgroup($|/) and so on.
KB_BLOCKED_PATHS=(
	"/AISURUbotnetproxy"
	"/russialoshara"
	"/qratorloshara"
	"/fuckyoumom"
	"/iemgroup"
)

# Host list for condition 6 (exact host match, case-insensitive via ~*):
KB_BLOCKED_HOSTS=(
	"example.com"
)

mkdir -p "$CONF_DIR"

# Build one regex from the prefix list (escape for regex)
build_path_regex() {
	local parts=()
	local p esc
	for p in "$@"; do
		[ -z "$p" ] && continue
		p="${p#/}"
		esc=$(printf '%s' "$p" | sed 's/[].[^$\\*+?{}|()]/\\&/g')
		parts+=("^/${esc}(\$|/)")
	done
	if [ "${#parts[@]}" -eq 0 ]; then
		return 1
	fi
	local IFS='|'
	printf '%s' "${parts[*]}"
}

PATH_REGEX=""
if PATH_REGEX="$(build_path_regex "${KB_BLOCKED_PATHS[@]}")"; then
	:
else
	PATH_REGEX=""
fi

PATH_MAP_LINES='    default 0;'
if [ -n "$PATH_REGEX" ]; then
	PATH_MAP_LINES="    default 0;
    ~*(${PATH_REGEX}) 1;"
fi

# Build one regex from the host list (escape for regex)
build_host_regex() {
	local parts=()
	local h esc
	for h in "$@"; do
		[ -z "$h" ] && continue
		esc=$(printf '%s' "$h" | sed 's/[].[^$\\*+?{}|()]/\\&/g')
		parts+=("${esc}")
	done
	if [ "${#parts[@]}" -eq 0 ]; then
		return 1
	fi
	local IFS='|'
	printf '%s' "${parts[*]}"
}

HOST_REGEX=""
if HOST_REGEX="$(build_host_regex "${KB_BLOCKED_HOSTS[@]}")"; then
	:
else
	HOST_REGEX=""
fi

HOST_MAP_LINES='    default 0;'
if [ -n "$HOST_REGEX" ]; then
	HOST_MAP_LINES="    default 0;
    ~*^(${HOST_REGEX})\$ 1;"
fi

cat > "$CONF_FILE" <<EOF
# ${CONF_FILE}
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Auto-block by query string and by path (before further proxying).

map \$args \$kb_has_blocked_param {
    default 0;
    ~*(^|&)(utm_term|mclkid|_ga|_gl|gclid|utm_source|utm_medium|utm_campaign|yclid|fbclid|_openstat|ref)(&|=|$) 1;
}

map \$args \$kb_no_params {
    ""      1;
    default 0;
}

map \$args \$kb_has_any_param {
    ""      0;
    default 1;
}

map \$args \$kb_has_allowed_param {
    default 0;
    ~*(^|&)(id|page|q|s|sort|order|category|product_id)(&|=|$) 1;
}

# Condition 5: path (normalized URI without query)
map \$uri \$kb_has_blocked_path {
${PATH_MAP_LINES}
}

# Condition 6: host is in the list
map \$host \$kb_has_blocked_host {
${HOST_MAP_LINES}
}

# Toggles (0/1). Off by default.
# Example of enabling for a specific domain:
# Set the domain that should enable this block. If you set "default 1;", the block is enabled for all domains.
# Example:   
#map \$host \$kb_block_if_bad_path         { # 5: URI (path) matched a forbidden prefix/pattern
#    default 0;
#    futbolki.tv 1;
#}  
# So for domain futbolki.tv the block is enabled when "URI (path) matched a forbidden prefix/pattern".

map \$host \$kb_block_if_has_blocked_param { # 1: a forbidden query parameter is present
    default 0;
    test-killbot.local 1;
}
map \$host \$kb_block_if_no_params        { # 2: query string is empty
    default 0;
    test-killbot.local 0;
}
map \$host \$kb_block_if_has_any_param    { # 3: any query parameter is present
    default 0;
    test-killbot.local 0;
}
map \$host \$kb_block_if_no_allowed       { # 4: none of the allowed parameters are present
    default 0;
    test-killbot.local 0;
}
map \$host \$kb_block_if_bad_path         { # 5: URI (path) matched a forbidden prefix/pattern
    default 0;
    test-killbot.local 1;
}   
map \$host \$kb_block_if_bad_host         { # 6: Host is in the forbidden list
    default 0;
    test-killbot.local 0;
}

# Result: 1 = block (any enabled condition)
map "\$kb_block_if_has_blocked_param:\$kb_block_if_no_params:\$kb_block_if_has_any_param:\$kb_block_if_no_allowed:\$kb_block_if_bad_path:\$kb_block_if_bad_host:\$kb_has_blocked_param:\$kb_no_params:\$kb_has_any_param:\$kb_has_allowed_param:\$kb_has_blocked_path:\$kb_has_blocked_host" \$kb_should_block {
    default 0;
    # 1) enabled and a forbidden query parameter was found
    ~^1:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:1: 1;

    # 2) enabled and query is empty
    ~^[^:]*:1:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:1: 1;

    # 3) enabled and query is NOT empty
    ~^[^:]*:[^:]*:1:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:1: 1;

    # 4) enabled, query is NOT empty, and there are NO allowed parameters
    ~^[^:]*:[^:]*:[^:]*:1:[^:]*:[^:]*:[^:]*:[^:]*:1:0: 1;

    # 5) enabled and the path is forbidden
    ~^[^:]*:[^:]*:[^:]*:[^:]*:1:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:1: 1;

    # 6) enabled and the host is forbidden
    ~^[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:1:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:1\$ 1;
}

# In server{} / location / before proxy_pass:
#   if (\$kb_should_block) { return 403; }
EOF

tmp="$(mktemp)"
awk -v a="${KB_BLOCK_IF_HAS_BLOCKED_PARAM}" \
	-v b="${KB_BLOCK_IF_NO_PARAMS}" \
	-v c="${KB_BLOCK_IF_HAS_ANY_PARAM}" \
	-v d="${KB_BLOCK_IF_NO_ALLOWED_PARAMS}" \
	-v e="${KB_BLOCK_IF_BAD_PATH}" \
	-v f="${KB_BLOCK_IF_BAD_HOST}" '
{
  # Do not use the name "in" — in awk it is a keyword and breaks parsing.
  if ($0 ~ /^map \$host \$kb_block_if_has_blocked_param/) { print; st1=1; next }
  if (st1==1 && $0 ~ /^    default /) { print "    default " a ";"; st1=0; next }

  if ($0 ~ /^map \$host \$kb_block_if_no_params/) { print; st2=1; next }
  if (st2==1 && $0 ~ /^    default /) { print "    default " b ";"; st2=0; next }

  if ($0 ~ /^map \$host \$kb_block_if_has_any_param/) { print; st3=1; next }
  if (st3==1 && $0 ~ /^    default /) { print "    default " c ";"; st3=0; next }

  if ($0 ~ /^map \$host \$kb_block_if_no_allowed/) { print; st4=1; next }
  if (st4==1 && $0 ~ /^    default /) { print "    default " d ";"; st4=0; next }

  if ($0 ~ /^map \$host \$kb_block_if_bad_path/) { print; st5=1; next }
  if (st5==1 && $0 ~ /^    default /) { print "    default " e ";"; st5=0; next }

  if ($0 ~ /^map \$host \$kb_block_if_bad_host/) { print; st6=1; next }
  if (st6==1 && $0 ~ /^    default /) { print "    default " f ";"; st6=0; next }

  print
}' "$CONF_FILE" > "$tmp"
mv "$tmp" "$CONF_FILE"
chmod 0644 "$CONF_FILE"

if [ -f "$NGINX_CONF" ] && ! grep -qE 'include[[:space:]]+/etc/nginx/conf\.d/\*\.conf;' "$NGINX_CONF"; then
	echo "Warning: $NGINX_CONF has no include /etc/nginx/conf.d/*.conf — add it inside http { } manually."
fi

echo "Written: $CONF_FILE"

# Path to the configuration file
PORTS_CONF="/etc/apache2/ports.conf"

# Check that the file exists and contains a port 8443 line
if [ -f "$PORTS_CONF" ] && grep -q "8443" "$PORTS_CONF"; then
    echo "File $PORTS_CONF already has a port 8443 config. Nothing to do."
else
    echo "Creating a new $PORTS_CONF with the required config..."
    
    # Create a backup if the file exists
    if [ -f "$PORTS_CONF" ]; then
        cp "$PORTS_CONF" "$PORTS_CONF.backup.$(date +%Y%m%d_%H%M%S)"
        echo "Backup of the existing file created"
    fi
    
    # Create a new file with the required contents
    cat > "$PORTS_CONF" << 'EOF'
Listen 127.0.0.1:8080 backlog=65535
Listen 127.0.0.1:8443 backlog=65535
EOF
    
    echo "File $PORTS_CONF was created/updated with the following contents:"
    echo "----------------------------------------"
    cat "$PORTS_CONF"
    echo "----------------------------------------"
fi

# so Apache receives the real client IP
sudo a2enmod remoteip
CONFIG_FILE="/etc/apache2/apache2.conf"
if ! grep -q "RemoteIPHeader X-Forwarded-For" "$CONFIG_FILE"; then
    echo "RemoteIPHeader X-Forwarded-For" | sudo tee -a "$CONFIG_FILE"
fi
if ! grep -q "RemoteIPTrustedProxy 127.0.0.1" "$CONFIG_FILE"; then
    echo "RemoteIPTrustedProxy 127.0.0.1" | sudo tee -a "$CONFIG_FILE"
fi
if ! grep -qE '^[[:space:]]*ListenBacklog[[:space:]]' "$CONFIG_FILE"; then
    echo "ListenBacklog 4096" | sudo tee -a "$CONFIG_FILE"
fi
sudo systemctl restart apache2

sudo sudo tee /etc/nginx/sites-available/$CURRENT_SERVER_IP.conf > /dev/null <<EOF
server {
    listen 80;
    server_name $CURRENT_SERVER_IP;

    include /etc/nginx/conf.d/killbot-too-many-requests.inc;

    # uncomment this during a DDoS
    #return 444;

    if (\$trash_request = 1) {
        return 444;
    }

    if (\$server_protocol = "HTTP/1.3") {
        return 444;
    }

    #if (\$args ~ .+) { return 444; }  # block if there is at least one query parameter (useful during DDoS)
    
    #if (\$args ~ (^|&)(param1|param2|param3)(=|&|\$)) { return 444; } # block if a query parameter is one of param1,param2,param3 (useful during DDoS)

    location /server-status {
        if (\$kb_should_block) { return 444; }

        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host "127.0.0.1";
        proxy_buffering off;
        allow 127.0.0.1;
        allow 31.211.65.236;
        deny all;
    }

    location / {
        if (\$kb_should_block) { return 444; }

        proxy_http_version 1.1;
        proxy_set_header Connection '';

        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
      #  proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/$CURRENT_SERVER_IP.conf /etc/nginx/sites-enabled/

sudo sudo tee /etc/nginx/sites-available/default > /dev/null <<EOF
server {
    listen 80 default_server;
    server_name _;

    include /etc/nginx/conf.d/killbot-too-many-requests.inc;

    # uncomment this during a DDoS
    #return 444;

    if (\$trash_request = 1) {
        return 444;
    }

    if (\$server_protocol = "HTTP/1.3") {
        return 444;
    }

    #if (\$args ~ .+) { return 444; }  # block if there is at least one query parameter (useful during DDoS)
    
    #if (\$args ~ (^|&)(param1|param2|param3)(=|&|\$)) { return 444; } # block if a query parameter is one of param1,param2,param3 (useful during DDoS)


    location /server-status {
        if (\$kb_should_block) { return 444; }

        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host "127.0.0.1";
        proxy_buffering off;
        allow 127.0.0.1;
        allow 31.211.65.236;
        deny all;
    }

    if (\$http_host = "") {
        return 444;
    }

#    if (\$http_host ~* "^[0-9\.]+$") {
#        return 444;
#    }

    if (\$http_host ~* "example\.ru") {
        return 444;
    }

    location / {

        if (\$kb_should_block) { return 444; }

        if (\$request_method = OPTIONS) {
            return 444;
        }

        if (\$http_host = "") {
            return 444;
        }

#        if (\$http_host ~* "^[0-9\.]+$") {
#            return 444;
#        }

        proxy_http_version 1.1;
        proxy_set_header Connection '';

        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
       # proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        # For all remaining junk
        #return 444;
    }
}

server {
    listen 443 ssl default_server;    
    server_name _;

    include /etc/nginx/conf.d/killbot-too-many-requests.inc;

    # uncomment this during a DDoS
    #return 444;

    #if (\$args ~ .+) { return 444; }  # block if there is at least one query parameter (useful during DDoS)
    
    #if (\$args ~ (^|&)(param1|param2|param3)(=|&|\$)) { return 444; } # block if a query parameter is one of param1,param2,param3 (useful during DDoS)

    if (\$trash_request = 1) {
        return 444;
    }

    if (\$server_protocol = "HTTP/1.3") {
        return 444;
    }

    if (\$http_host = "") {
        return 444;
    }

#    if (\$http_host ~* "^[0-9\.]+$") {
#        return 444;
#    }

    if (\$http_host ~* "example\.ru") {
        return 444;
    }

    # SSL certificates
    ssl_certificate      /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;
    
    location / {

        if (\$kb_should_block) { return 444; }

        proxy_ssl_server_name on;
        proxy_ssl_name \$host;
        proxy_ssl_verify off;

        proxy_http_version 1.1;
        proxy_set_header Connection '';

        proxy_pass https://127.0.0.1:8443;
        proxy_set_header Host \$host;
        #proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        #proxy_set_header X-Forwarded-Proto \$scheme;
        #proxy_set_header X-Forwarded-Host \$host;
        #proxy_set_header X-Forwarded-Port \$server_port;
    } 

    # Redirect back to HTTP
    # return 301 http://\$host\$request_uri;
}

EOF


sudo sudo tee /etc/apache2/sites-available/000-default.conf > /dev/null <<EOF
<VirtualHost 127.0.0.1:8080>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html

    RewriteEngine On

    # === 2. Block OPTIONS ===
    RewriteCond %{REQUEST_METHOD} ^OPTIONS$
    RewriteRule ^ - [F]

    # === 3. Block empty Host ===
    RewriteCond %{HTTP_HOST} ^$
    RewriteRule ^ - [F]

    RewriteCond %{REQUEST_URI} !^/kb.php$
    RewriteCond %{REQUEST_URI} !^/le_receive_cert.php$
    RewriteCond %{REQUEST_URI} !^/empty.php$
    RewriteCond %{REQUEST_URI} !^/le_custom_server/request.php$
    RewriteRule ^ /empty.php [L]

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined

</VirtualHost>
<VirtualHost 127.0.0.1:8443>

    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html

    RewriteEngine On

    # === 2. Block OPTIONS ===
    RewriteCond %{REQUEST_METHOD} ^OPTIONS$
    RewriteRule ^ - [F]

    # === 3. Block empty Host ===
    RewriteCond %{HTTP_HOST} ^$
    RewriteRule ^ - [F]

    RewriteCond %{REQUEST_URI} !^/kb.php$
    RewriteCond %{REQUEST_URI} !^/le_receive_cert.php$
    RewriteCond %{REQUEST_URI} !^/empty.php$
    RewriteCond %{REQUEST_URI} !^/le_custom_server/request.php$
    RewriteRule ^ /empty.php [L]

    SSLEngine on

    SSLCertificateFile      /etc/ssl/certs/ssl-cert-snakeoil.pem
    SSLCertificateKeyFile /etc/ssl/private/ssl-cert-snakeoil.key

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined

</VirtualHost>

<VirtualHost 127.0.0.1:8080>
    ServerName $CURRENT_SERVER_IP
    DocumentRoot /var/www/html

    RewriteEngine On

    RewriteCond %{REQUEST_METHOD} ^OPTIONS

    RewriteRule .* - [R=403,L]

  <Directory "/var/www/html">
        Require all denied
        <Files "kb.php">
            Require all granted
        </Files>
        <Files "le_receive_cert.php">
            Require all granted
        </Files>
    </Directory>
</VirtualHost>
EOF



sysctl --system
sysctl net.ipv4.tcp_syncookies net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_synack_retries

# Install acme.sh for wildcard SSL certificates

# Check if acme.sh is already installed
if [ ! -f "/root/.acme.sh/acme.sh" ]; then
    echo "Installing acme.sh..."
    curl https://get.acme.sh | sh -s email=admin@killbot.ru
else
    echo "acme.sh is already installed, skipping installation..."
fi

sudo mkdir -p /usr/local/bin

# Create symbolic link (force overwrite if exists)
sudo ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh
sudo chmod +x /usr/local/bin/acme.sh

echo "Custom DNS hook for Reg.ru with SSL certificate support created successfully!"

# Create DNS hooks for Russian hosting providers
sudo tee /root/.acme.sh/dnsapi/dns_beget.sh > /dev/null <<'EOF'
#!/usr/bin/env sh

# Beget DNS API integration for acme.sh
# Corrected implementation using changeRecords endpoint
# https://beget.com/

dns_beget_add() {
  fulldomain=$1
  txtvalue=$2

  BEGET_LOGIN="${BEGET_LOGIN:-$(_readaccountconf_mutable BEGET_LOGIN)}"
  BEGET_PASSWORD="${BEGET_PASSWORD:-$(_readaccountconf_mutable BEGET_PASSWORD)}"

  if [ -z "$BEGET_LOGIN" ] || [ -z "$BEGET_PASSWORD" ]; then
    _err "You didn't specify Beget login or password."
    return 1
  fi

  _saveaccountconf_mutable BEGET_LOGIN "$BEGET_LOGIN"
  _saveaccountconf_mutable BEGET_PASSWORD "$BEGET_PASSWORD"

  _info "Adding TXT record for $fulldomain"

  # 1️⃣ Get all current TXT records from the local cache (if any)
  _readaccountconf BEGET_TXT_CACHE
  if [ -n "$BEGET_TXT_CACHE" ]; then
    current_txts="$BEGET_TXT_CACHE"
  else
    current_txts=""
  fi

  # 2️⃣ Add the new value to the list
  new_txts="${current_txts}${txtvalue} "

  # 3️⃣ Build JSON including all TXT records
  txt_json=""
  for t in $new_txts; do
    txt_json="${txt_json}{\"priority\":10,\"value\":\"$t\"},"
  done
  txt_json="[${txt_json%,}]"

  input_data=$(printf '{"fqdn":"%s","records":{"TXT":%s}}' "$fulldomain" "$txt_json")

  # 4️⃣ Send the request
  response=$(curl -s "https://api.beget.com/api/dns/changeRecords" \
    -G \
    --data-urlencode "login=$BEGET_LOGIN" \
    --data-urlencode "passwd=$BEGET_PASSWORD" \
    --data-urlencode "input_format=json" \
    --data-urlencode "output_format=json" \
    --data-urlencode "input_data=$input_data")

  if echo "$response" | grep -q 'true'; then
    _info "✅ TXT record added OK"
    _saveaccountconf_mutable BEGET_TXT_CACHE "$new_txts"
    return 0
  else
    _err "❌ Failed to add TXT record: $response"
    return 1
  fi
}

dns_beget_rm() {
  fulldomain=$1
  txtvalue=$2

  _readaccountconf BEGET_TXT_CACHE
  if [ -n "$BEGET_TXT_CACHE" ]; then
    new_cache=$(echo "$BEGET_TXT_CACHE" | sed "s/$txtvalue//g")
    _saveaccountconf_mutable BEGET_TXT_CACHE "$new_cache"
  fi

  _info "Removing TXT record for $fulldomain (not supported by Beget API)"
  return 0
}

EOF

# Make DNS hooks executable
sudo chmod +x /root/.acme.sh/dnsapi/dns_beget.sh
sudo chmod +x /root/.acme.sh/dnsapi/dns_timeweb.sh

# Create placeholder DNS hooks for other Russian providers
for provider in sprinthost spaceweb fornex adminvps; do
    sudo tee "/root/.acme.sh/dnsapi/dns_${provider}.sh" > /dev/null <<EOF
#!/usr/bin/env sh

# ${provider^} DNS API
# Placeholder implementation - requires provider-specific API integration

dns_${provider}_add() {
    fulldomain=\$1
    txtvalue=\$2
    
    _err "${provider^} DNS API integration not yet implemented"
    _err "Please contact support or use a different DNS provider"
    return 1
}

dns_${provider}_rm() {
    fulldomain=\$1
    txtvalue=\$2
    
    _info "TXT record removal for ${provider^} not implemented"
    return 0
}
EOF
    sudo chmod +x "/root/.acme.sh/dnsapi/dns_${provider}.sh"
done

sudo a2enmod security2
sudo a2enmod reqtimeout
#sudo apt install lua-md5
#sudo apt install luarocks
#sudo luarocks install md5
#sudo a2enmod lua

sudo mkdir -p /var/log/apache2/
sudo chown -R www-data:www-data /var/log/apache2/
sudo chmod -R 755 /var/log/apache2/

#sudo mkdir -p /var/www/html/webroot
#sudo chown -R www-data:www-data /var/www/html/webroot

#####################
#MPM_MODE="mpm_event"  
MPM_MODE="mpm_prefork"   # event by default

if [[ "$OS_VERSION" == "22.04" ]]; then
    PHP_VERSION="8.1"
    PHP_VERSION_APACHE="8.1"
else
    PHP_VERSION="7.4"
    PHP_VERSION_APACHE="7.4"
fi

#PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
#echo "PHP version is $PHP_VERSION"

#PHP_CONF=$(ls /etc/apache2/mods-enabled/ 2>/dev/null | grep -oE 'php[0-9]+\.[0-9]+\.conf' | head -n1)

#if [[ -n "$PHP_CONF" ]]; then
#    PHP_VERSION_APACHE=$(echo "$PHP_CONF" | grep -oE '[0-9]+\.[0-9]+')
#    echo "✅ Apache PHP $PHP_VERSION_APACHE (mod_php)"
#fi

# If mod_php is not found — look for a php-fpm socket
#FPM_CONF=$(grep -R "php[0-9]\.[0-9]-fpm" /etc/apache2/sites-enabled/ 2>/dev/null | head -n1)
#if [[ -n "$FPM_CONF" ]]; then
#    PHP_VERSION_APACHE=$(echo "$FPM_CONF" | grep -oE 'php[0-9]+\.[0-9]+')
#    echo "✅ Apache PHP $PHP_VERSION_APACHE (php-fpm)"
#fi

if [[ "$MPM_MODE" == "mpm_event" ]]; then
    # mpm_event + php-fpm
    echo "Configuring for mpm_event with php-fpm..."        
    sudo a2dismod "php$PHP_VERSION_APACHE"
    sudo apt install -y "php${PHP_VERSION}-fpm"
    sudo a2enconf "php${PHP_VERSION_APACHE}-fpm"
    sudo a2enmod proxy_fcgi setenvif    

    sudo a2dismod mpm_worker    
    sudo a2dismod mpm_prefork

    sudo a2enmod mpm_event
    
elif [[ "$MPM_MODE" == "mpm_prefork" ]]; then

    sudo apt install -y "php${PHP_VERSION}-fpm"
    echo "Configuring for mpm_prefork with mod_php..."        
    sudo a2disconf "php${PHP_VERSION_APACHE}-fpm"
    
    # remove php-fpm if needed
    # sudo apt remove -y "php${PHP_VERSION}-fpm"

    sudo a2dismod mpm_worker    
    sudo a2dismod mpm_event    

    sudo a2dismod proxy_fcgi
    sudo a2enmod "php$PHP_VERSION_APACHE"
    
    sudo a2enmod mpm_prefork
else
    echo "Unknown MPM mode: $MPM_MODE"
    exit 1
fi
#####################

sudo apt install lua5.1
sudo apt install lua-md5
sudo apt install luarocks
#sudo luarocks install md5 || true
sudo a2enmod lua

rm -rf /var/log/apache2/*
rm -rf /var/log/killbot/*
rm -f /opt/killbot/killbot_revers
rm -f /opt/killbot/settings/*/killbot_revers

sudo systemctl restart apache2

echo "Apache + PHP is installed."

sudo apt install dnsutils

sudo apt install -y certbot python3-certbot-apache

echo "Certbot for SSL has been installed."

sudo apt install -y curl
sudo apt install jq -y

sudo mkdir -p /opt/killbot
sudo mkdir -p /opt/killbot/php
sudo mkdir -p /opt/killbot/lua
sudo mkdir -p /opt/killbot/sh
sudo mkdir -p /opt/killbot/f2b
sudo mkdir -p /opt/killbot/certs
sudo mkdir -p /opt/killbot/ssl
sudo mkdir -p /opt/killbot/settings
sudo mkdir -p /var/log/killbot
sudo mkdir -p /var/log/killbot/ssh
sudo mkdir -p /var/log/killbot/lua
sudo mkdir -p /opt/killbot/html
sudo chown -R www-data:www-data /var/log/killbot /var/log/killbot/lua /opt/killbot/lua /opt/killbot/php /opt/killbot/sh /opt/killbot/html
sudo chown -R www-data:www-data /opt/killbot/settings/
sudo chown www-data:www-data /opt/killbot/ssl
sudo chmod 775 /opt/killbot/ssl

echo "  permissions OK: /opt/killbot/ssl (www-data:www-data 775)"

# Create the countries config only if the file is missing
if [ ! -f /opt/killbot/f2b/block_all_countries_except.config ]; then  
  cat > /opt/killbot/f2b/block_all_countries_except.config <<'EOC'
# Config file for block_all_countries_except.sh
# Set a country code (for example RU, US, DE, FR, etc.)
# You can list several countries separated by commas: COUNTRY="RU,BY,GE"
COUNTRIES="RU,BY"
PORTS="443,80,22"
EOC
fi

sudo touch /opt/killbot/tokens

# Check if file exists, if not create it with the IP address
if [ ! -f "/opt/killbot/wl-ip" ]; then    
    # Default white-list ips
    echo -e "37.140.192.59" > /opt/killbot/wl-ip  # Overwrite existing file
fi

if [ ! -f "/opt/killbot/wl-path" ]; then    
    # Default wl-path
    echo -e "/favicon.ico" > /opt/killbot/wl-path  # Overwrite existing file
fi

if [ ! -f "/opt/killbot/wl-ua" ]; then    
    # Default white-list user agents
    echo -e "yandex.bot\ngoogle.bot\nbaidu.bot\nWhatsApp.W\nbing.bot\nfacebook.bot\nvk.bot\ninstagram.bot\ntwitter.bot\nlinkedin.bot\npinterest.bot\nviber.bot\nslack.bot\nskype.bot\ntelegram.bot\nwhatsapp.bot\nletsencrypt" > /opt/killbot/wl-ua
fi

FILE="/opt/killbot/html/verification.php"
if [ ! -f "$FILE" ]; then    
    kb_download "$FILE" "html/verification.html"
    
    if [ $? -eq 0 ]; then
        echo "The verification page has been successfully loaded."
    else
        echo "Error loading the verification page."
        exit 1
    fi
    #sudo test -f /var/www/html/.htaccess || sudo tee /var/www/html/.htaccess > /dev/null <<EOF
    #<FilesMatch "\.(html|htm)$">
    #    Header set Cache-Control "no-cache, no-store, must-revalidate"
    #    Header set Pragma "no-cache"
    #    Header set Expires 0
    #</FilesMatch>
fi

FILE="/var/www/html/empty.php"
    kb_download "$FILE" "html/empty_nginx.html"
    
    if [ $? -eq 0 ]; then
        echo "The empty php page has been successfully loaded."
    else
        echo "Error loading the empty php page."
        exit 1
    fi

FILE="/var/www/html/empty_ru.html"
    kb_download "$FILE" "html/empty_ru.html"
    
    if [ $? -eq 0 ]; then
        echo "The empty RU page has been successfully loaded."
    else
        echo "Error loading the empty RU page."
        exit 1
    fi

FILE="/var/www/html/empty_en.html"
    kb_download "$FILE" "html/empty_en.html"
    
    if [ $? -eq 0 ]; then
        echo "The empty EN page has been successfully loaded."
    else
        echo "Error loading the empty EN page."
        exit 1
    fi

FILE="/opt/killbot/UpdateAll.sh"
    kb_download "$FILE" "sh/UpdateAll_nginx.sh"
    
    if [ $? -eq 0 ]; then
        echo "The UpdateAll.sh file has been successfully loaded."
    else
        echo "Error loading the UpdateAll.sh file."
        exit 1
    fi

FILE="/opt/killbot/renew_wildcard.sh"
    kb_download "$FILE" "sh/renew_wildcard.sh"
    
    if [ $? -eq 0 ]; then
        echo "The renew_wildcard.sh file has been successfully loaded."
    else
        echo "Error loading the renew_wildcard.sh file."
        exit 1
    fi

FILE="/opt/killbot/acme_check_api.sh"
    kb_download "$FILE" "sh/acme_check_api.sh"
    
    if [ $? -eq 0 ]; then
        echo "The acme_check_api.sh file has been successfully loaded."
    else
        echo "Error loading the acme_check_api.sh file."
        exit 1
    fi

FILE="/opt/killbot/official_allowed_ips.sh"
    kb_download "$FILE" "sh/official_allowed_ips.sh"
    
    if [ $? -eq 0 ]; then
        echo "The official_allowed_ips.sh file has been successfully loaded."
    else
        echo "Error loading the official_allowed_ips.sh file."
        exit 1
    fi

FILE="/opt/killbot/html/FakeBot.php"
if [ ! -f "$FILE" ]; then
    kb_download "$FILE" "html/FakeBot.html"

    if [ $? -eq 0 ]; then
        echo "FakeBot page loaded."
    else
        echo "Error loading the FakeBot page."
        exit 1
    fi
fi


FILE="/opt/killbot/html/BlockBot.html"
if [ ! -f "$FILE" ]; then
    kb_download "$FILE" "html/BlockBot.html"

    if [ $? -eq 0 ]; then
        echo "BlockBot page loaded."
    else
        echo "Error loading the BlockBot page."
        exit 1
    fi
fi

FILE="/opt/killbot/html/Expired.html"
if [ ! -f "$FILE" ]; then
    kb_download "$FILE" "html/Expired.html"

    if [ $? -eq 0 ]; then
        echo "Expired page loaded."
    else
        echo "Error loading the Expired page."
        exit 1
    fi
fi


FILE="/opt/killbot/f2b/subnet-monitor.sh"
    kb_download "$FILE" "sh/subnet-monitor.sh"

    if [ $? -eq 0 ]; then
        echo "subnet-monitor loaded."
    else
        echo "Error loading the subnet-monitor."
        exit 1
    fi

FILE="/opt/killbot/f2b/unblock_traffic.sh"
    kb_download "$FILE" "sh/unblock_traffic.sh"

    if [ $? -eq 0 ]; then
        echo "unblock_traffic loaded."
    else
        echo "Error loading the unblock_traffic.sh"
        exit 1
    fi


FILE="/opt/killbot/f2b/check_apache_and_block.sh"
    kb_download "$FILE" "sh/check_apache_and_block.sh"

    if [ $? -eq 0 ]; then
        echo "check_apache_and_block.sh loaded."
    else
        echo "Error loading the check_apache_and_block."
        exit 1
    fi

FILE="/opt/killbot/f2b/block_all_countries_except.sh"
    kb_download "$FILE" "sh/block_all_countries_except.sh"

    if [ $? -eq 0 ]; then
        echo "block_all_countries_except.sh loaded."
    else
        echo "Error loading the block_all_countries_except."
        exit 1
    fi

FILE="/opt/killbot/cert_delete.sh"
    kb_download "$FILE" "sh/cert_delete.sh"

    if [ $? -eq 0 ]; then
        echo "cert_delete loaded."
    else
        echo "Error loading the cert_delete."
        exit 1
    fi

FILE="/opt/killbot/html/access_denied.html"
if [ ! -f "$FILE" ]; then
    kb_download "$FILE" "html/access_denied.html"

    if [ $? -eq 0 ]; then
        echo "access_denied loaded."
    else
        echo "Error loading the access_denied.html"
        exit 1
    fi
fi

FILE="/opt/killbot/html/too_many_requests.html"
if [ ! -f "$FILE" ]; then
    kb_download "$FILE" "html/too_many_requests.html"

    if [ $? -eq 0 ]; then
        echo "too_many_requests loaded."
    else
        echo "Error loading the too_many_requests.html"
        exit 1
    fi
fi

FILE="/var/www/html/le_receive_cert.php"
    kb_download "$FILE" "html/le_custom_server/le_receive_cert.html"

    if [ $? -eq 0 ]; then
        echo "le_receive_cert.php loaded."
    else
        echo "Error loading le_receive_cert.html"
        exit 1
    fi

sudo chown www-data:www-data /var/www/html/le_receive_cert.php
sudo chmod 644 /var/www/html/le_receive_cert.php

FILE="/opt/killbot/check_killbot_reverse_proxy.sh"
    kb_download "$FILE" "sh/check_killbot_reverse_proxy.sh"
    
    if [ $? -eq 0 ]; then
        echo "The check_killbot_reverse_proxy.sh file has been successfully loaded."
    else
        echo "Error loading the check_killbot_reverse_proxy.sh file."
        exit 1
    fi

FILE="/opt/killbot/setup_killbot_reverse_proxy.sh"
    kb_download "$FILE" "sh/setup_killbot_reverse_proxy.sh"
    
    if [ $? -eq 0 ]; then
        echo "The setup_killbot_reverse_proxy.sh file has been successfully loaded."
    else
        echo "Error loading the setup_killbot_reverse_proxy.sh file."
        exit 1
    fi

FILE="/opt/killbot/update-postrouting.sh"
    kb_download "$FILE" "sh/update-postrouting.sh"
    
    if [ $? -eq 0 ]; then
        echo "The update-postrouting.sh has been successfully loaded."
    else
        echo "Error loading the update-postrouting.sh."
        exit 1
    fi

FILE="/opt/killbot/update-symmetric-ip.sh"
    kb_download "$FILE" "sh/update-symmetric-ip.sh"
    
    if [ $? -eq 0 ]; then
        echo "The update-symmetric-ip.sh has been successfully loaded."
    else
        echo "Error loading the update-symmetric-ip.sh."
        exit 1
    fi

FILE="/opt/killbot/check_host_curl.sh"
    kb_download "$FILE" "sh/check_host_curl.sh"
    
    if [ $? -eq 0 ]; then
        echo "The check_host_curl.sh has been successfully loaded."
    else
        echo "Error loading the check_host_curl.sh."
        exit 1
    fi
    

FILE="/opt/killbot/dns_provider_hint.sh"
    kb_download "$FILE" "sh/dns_provider_hint.sh"
    if [ $? -eq 0 ]; then
        echo "The dns_provider_hint.sh file has been successfully loaded."
    else
        echo "Error loading the dns_provider_hint.sh file."
        exit 1
    fi

sudo chmod +x /opt/killbot/check_killbot_reverse_proxy.sh /opt/killbot/setup_killbot_reverse_proxy.sh /opt/killbot/update-postrouting.sh /opt/killbot/update-symmetric-ip.sh /opt/killbot/check_host_curl.sh
sudo chmod 644 /opt/killbot/dns_provider_hint.sh

sudo chown www-data:www-data /opt/killbot/html/FakeBot.php /opt/killbot/html/BlockBot.html /opt/killbot/html/Expired.html /opt/killbot/html/verification.php
sudo chmod +x /opt/killbot/f2b/subnet-monitor.sh /opt/killbot/renew_wildcard.sh /opt/killbot/acme_check_api.sh /opt/killbot/UpdateAll.sh /opt/killbot/official_allowed_ips.sh
sudo chmod +x /opt/killbot/cert_delete.sh /opt/killbot/f2b/block_all_countries_except.sh /opt/killbot/f2b/check_apache_and_block.sh /opt/killbot/f2b/unblock_traffic.sh

sudo tee /opt/killbot/kbEqual.php > /dev/null <<EOF
#!/usr/bin/php
<?php

\$stdin = fopen("php://stdin", "r");
\$logFile = '/var/log/killbot/kbEqual.log';

while ((\$line = fgets(\$stdin)) !== false) {
    \$line = trim(\$line);
    if (empty(\$line)) {
        continue;
    }
    list(\$value1, \$value2) = explode('.', \$line);
    echo (strcmp(\$value1, \$value2) === 0) ? "true\n" : "false\n";
    fflush(STDOUT);
}

fclose(\$stdin);
EOF

sudo chmod +x /opt/killbot/kbEqual.php

sudo sudo tee /opt/killbot/kb.lua > /dev/null <<EOF
package.path = "/usr/local/share/lua/5.1/?.lua;" .. package.path
package.cpath = "/usr/local/lib/lua/5.1/?.so;" .. package.cpath

package.path = "/usr/share/lua/5.2/?.lua;/usr/share/lua/5.2/?/init.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.2/?.so;/usr/lib/x86_64-linux-gnu/lua/5.2/?/core.so;/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;/usr/lib/x86_64-linux-gnu/lua/5.1/?/core.so;" .. package.cpath

local md5 = require "md5"

local cache = cache or {}
local lastFlush = 0
local lifetime = 86400
local LOG_ENABLED = false
local DNS_SERVER = "8.8.8.8"
-- "77.88.8.8"

function log_message(message,domain)
    if not LOG_ENABLED then return false end

    local f = io.open("/var/log/killbot/lua/" .. domain .. ".log", "a")
    if f then
        f:write(message .. "\n")
        f:close()
    end
end

kb_lua_agents

kb_lua_paths

kb_lua_ips

local disallowed_paths = {}

local function load_disallowed_paths(file_path)
    local paths = {}
    local f = io.open(file_path, "r")
    if not f then
        return paths
    end

    for line in f:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            table.insert(paths, line)
        end
    end

    f:close()
    return paths
end

disallowed_paths = load_disallowed_paths("/opt/killbot/settings/kb_domain/disallowed_paths.txt")

local function load_dns_bots_allowed(file_path)
    local engines = {}
    local f = io.open(file_path, "r")

    if not f then
        log_message("dns bots file open failed: " .. tostring(file_path), "trafficgen.net")
        return engines
    end

    for line in f:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")

        if line ~= "" and line:sub(1,1) ~= "#" then
            local bot_pattern, domains = line:match("([^|]+)|(.+)")

            if bot_pattern and domains then
                local hostname_patterns = {}

                for domain in domains:gmatch("([^,]+)") do
                    domain = domain:gsub("^%s+", ""):gsub("%s+$", "")
                    table.insert(hostname_patterns, domain)
                end

                table.insert(engines, {
                    bot_pattern = bot_pattern,
                    hostname_patterns = hostname_patterns
                })
            end
        end
    end

    f:close()
    return engines
end

local function path_disallowed(path)
    for _, pattern in ipairs(disallowed_paths) do
        if pattern:sub(-1) == "$" then
            local exact = pattern:sub(1, -2)
            if path == exact then
                return true
            end
        else
            if path:sub(1, #pattern) == pattern then
                return true
            end
        end
    end
    return false
end

local function agent_allowed(agent)
    
    if not agent then return false end

    agent = agent:lower()

    for _, pattern in ipairs(allowed_agents) do
        local all_found = true                
        for word in pattern:gmatch("[^%.]+") do
            if word ~= "" and not agent:find(word:lower(), 1, true) then                
                all_found = false
                break
            end
        end

        if all_found then
            return true
        end
    end

    return false
end

function check_dns_works()
    local cmd = "dig +short @" .. DNS_SERVER .. " google.com 2>/dev/null | grep -E '^[0-9]+\\\.[0-9]+\\\.[0-9]+\\\.[0-9]+$' | head -1"
    local handle = io.popen(cmd)
    local result = handle:read("*l")
    handle:close()
    
    return (result and result ~= "")
end

-- Helper to resolve a hostname to IP via the given DNS server
function get_hostname_ips(hostname)
    local ips = {}

    local cmd = "dig +short @" .. DNS_SERVER .. " " .. hostname .. " 2>/dev/null | grep -E '^[0-9]+\\\.[0-9]+\\\.[0-9]+\\\.[0-9]+$'"
    local handle = io.popen(cmd)
    if handle then
        local result = handle:read("*a")
        handle:close()

        for ip in string.gmatch(result, "%d+%.%d+%.%d+%.%d+") do
            table.insert(ips, ip)
        end
    end

    if #ips == 0 then
        local cmd = "nslookup " .. hostname .. " " .. DNS_SERVER .. " 2>/dev/null | grep 'Address: ' | grep -v '#'"
        local handle = io.popen(cmd)
        if handle then
            local result = handle:read("*a")
            handle:close()

            for ip in string.gmatch(result, "%d+%.%d+%.%d+%.%d+") do
                table.insert(ips, ip)
            end
        end
    end

    return ips
end

function check_hostname(hostname, user_agent, client_ip)

    if not client_ip or client_ip == "" then
        return "bot_false"
    end

    local bots = load_dns_bots_allowed("/opt/killbot/settings/kb_domain/dns_bots_allowed.txt")

    local ua = string.lower(user_agent or "")
    local bot_ua_found = false

    for _, data in pairs(bots) do
        if string.find(ua, string.lower(data.bot_pattern), 1, true) then
            bot_ua_found = true

            if not hostname or hostname == "" then
                break
            end

            local hostname_ok = false
            for _, pattern in ipairs(data.hostname_patterns) do
                if #pattern <= #hostname and hostname:sub(-#pattern):lower() == pattern:lower() then
                    hostname_ok = true
                    break
                end
            end

            if not hostname_ok then
                return "bot_false"
            end

            local dns_ips = get_hostname_ips(hostname)
            for _, ip in ipairs(dns_ips) do
                if ip == client_ip then
                    return "bot_true"
                end
            end

            return "bot_false"
        end
    end

    if bot_ua_found then
        return "bot_false"
    end

    return "user"
end

function modifyMd5(input)
    return md5.sumhexa(input)
end


local function ip_allowed(ip)
    for _, pattern in ipairs(allowed_ips) do
        if pattern:sub(-1) == "." then
            if ip:sub(1, #pattern) == pattern then
                return true
            end
        elseif ip == pattern then
            return true
        end
    end
    return false
end

local function path_allowed(path)
    for _, pattern in ipairs(allowed_paths) do
        if pattern:sub(-1) == "$" then
            local exact = pattern:sub(1, -2)
            if path == exact then
                return true
            end
        else
            if path:sub(1, #pattern) == pattern then
                return true
            end
        end
    end
    return false
end

local allowed_ips_cache = nil

local function ipv4_to_number(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)

    if not a or not b or not c or not d then
        return nil
    end

    if a < 0 or a > 255 or b < 0 or b > 255 or c < 0 or c > 255 or d < 0 or d > 255 then
        return nil
    end

    return a * 16777216 + b * 65536 + c * 256 + d
end

local function ip_in_cidr(ip, cidr)
    local network, prefix = cidr:match("^([%d%.]+)/(%d+)$")
    prefix = tonumber(prefix)

    if not network or not prefix or prefix < 0 or prefix > 32 then
        return false
    end

    local ip_num = ipv4_to_number(ip)
    local net_num = ipv4_to_number(network)

    if not ip_num or not net_num then
        return false
    end

    if prefix == 0 then
        return true
    end

    local block_size = 2 ^ (32 - prefix)
    return math.floor(ip_num / block_size) == math.floor(net_num / block_size)
end

local function load_allowed_prefixes(filename)
    local prefixes = {}
    local file = io.open(filename, "r")
    if not file then
        return prefixes
    end

    for line in file:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and not line:match("^#") then
            prefixes[#prefixes + 1] = line
        end
    end

    file:close()
    return prefixes
end

local function is_ip_in_allowed_url(ip, host)
    if not ip or ip == "" then
        return false
    end

    local allowed_file = "/opt/killbot/settings/kb_domain/official_allowed_ips_genetated.txt"

    if not allowed_ips_cache then
        allowed_ips_cache = load_allowed_prefixes(allowed_file)
    end

    for i = 1, #allowed_ips_cache do
        if ip_in_cidr(ip, allowed_ips_cache[i]) then
            return true
        end
    end

    return false
end

function handle(r)
    local user_agent = r.headers_in["User-Agent"] or ""
    local remote_addr = r.subprocess_env["REAL_REMOTE_ADDR"] or ""
    local kb_session = r.subprocess_env["KBSESSION"] or ""
    local http_host = r.headers_in["Host"] or ""
    local http_host2 = ""

-- deny not exist 1.3 protokol: ddos case
    if r.protocol == "HTTP/1.3" then        
     -- return apache2.DONE
        return apache2.FORBIDDEN --FORCE LUA ERROR TO PREVENT CPU
    end

    local remote_addr_org = remote_addr
    local current_path = r.uri or "/"

    if path_disallowed(current_path) then
        local cmd = 'cat /opt/killbot/html/access_denied.html'
        local handle = io.popen(cmd)
        local result = handle:read("*a")
        handle:close()

        r.status = 403
        r.content_type = "text/html; charset=UTF-8"
        r:puts(result)

        log_message("ip:" .. remote_addr_org .. " disallowed path: " .. current_path .. " access denied page showed DONE", http_host)

        return apache2.DONE
    end

    if is_ip_in_allowed_url(remote_addr, http_host) then
        return apache2.DECLINED
    end

--[[
--  deny request with any get params: if ddos
    if r.args and #r.args > 0 then
        log_message("ip:" .. (r.subprocess_env["REAL_REMOTE_ADDR"] or "") .. " GET parameters detected: " .. r.args .. " - 403 FORBIDDEN", r.headers_in["Host"] or "")
        -- return apache2.DONE
        return apache2.FORBIDDEN --FORCE LUA ERROR TO PREVENT CPU
    end
]]

--[[
--  deny request with 1 get param and get param len = 4 and get param val = 4 and param val is not int: if ddos
if r.args and #r.args > 0 then
    local params = {}
    for k, v in string.gmatch(r.args, "([^=&]+)=([^&]*)") do
        params[k] = v
    end

    local count = 0
    for _ in pairs(params) do count = count + 1 end

    if count == 1 then
        for key, val in pairs(params) do
            local key_len = #key
            local val_len = #val

            local val_is_number = string.match(val, "^%d+$") ~= nil

            if key_len == 4 and val_len == 4 and not val_is_number then
                -- log_message("ip:" .. (r.subprocess_env["REAL_REMOTE_ADDR"] or "") .. " Suspicious 4=4 GET param detected: " .. key .. "=" .. val .. " - 403 FORBIDDEN", r.headers_in["Host"] or "" )
                -- return apache2.DONE
                return apache2.FORBIDDEN --FORCE LUA ERROR TO PREVENT CPU

            end
        end
    end
end
]]

    -- Extract second-level domain for http_host2
    if http_host ~= "" then
        local host = http_host:gsub(":%d+$", "")
    
        local parts = {}
        for label in host:gmatch("([^.]+)") do
            parts[#parts+1] = label
        end

        if #parts >= 2 then
            http_host2 = parts[#parts-1] .. "." .. parts[#parts]
        else            
            http_host2 = host
        end
    end
        
    local x_forwarded_for = r.headers_in["X-Forwarded-For"] or ""
    local path = r.uri or ""

    if r.uri == "/verification.php" then
        return apache2.DECLINED
    end

    if r.uri == "/FakeBot.php" then
        return apache2.DECLINED
    end

    if r.uri == "/access_denied.html" then
        return apache2.DECLINED
    end

    if r.uri == "/too_many_requests.html" then
        return apache2.DECLINED
    end

    if ip_allowed(remote_addr_org) then
        log_message("ip:"  .. remote_addr_org .. " ip_allowed: " .. remote_addr_org .. " DECLINED",http_host)
        return apache2.DECLINED
    end

    if path_allowed(r.unparsed_uri) then
        log_message("ip:"  .. remote_addr_org .. " path_allowed: " .. r.unparsed_uri .. " DECLINED",http_host)
        return apache2.DECLINED
    end

    local hostname = ""
    local handle = io.popen("host " .. remote_addr_org)
    if handle then
        local result = handle:read("*a")
        handle:close()
        if result then
            hostname = string.match(result, "domain name pointer ([^%s]+)%.") or ""
        end
    end

    local is_real_bot = check_hostname(hostname, user_agent, remote_addr_org)
    
    if is_real_bot == "bot_false" then
        local cmd = string.format('php /opt/killbot/html/FakeBot.php %q %q %q', x_forwarded_for ,remote_addr_org,user_agent)
        local handle = io.popen(cmd)
        local result = handle:read("*a")
        handle:close()
        r.content_type = "text/html"
        r:puts(result)

        log_message("ip:"  .. remote_addr_org .. " fake bot detected: " .. user_agent .. " fake bot page showed DONE",http_host)

        return apache2.DONE
    end

    if agent_allowed(user_agent) then
        log_message("ip:"  .. remote_addr_org .. " trusted user agent detected : " .. user_agent .. " DECLINED",http_host)
        return apache2.DECLINED
    end

--    r.headers_out["X-Debug-User-Agent"]  = user_agent
--    r.headers_out["X-Debug-Remote-Addr"] = remote_addr
--    r.headers_out["X-Debug-KB-Session"]  = kb_session
--    r.headers_out["X-Debug-Host"]        = http_host

    if #kb_session >=1 then
        local ct = tonumber(string.sub(kb_session, 1, -5))
        local now = math.floor(os.time() * 1000)

        if  ct == nil or math.abs(now - ct) > (lifetime * 1000) then
--          r.filename = "/opt/killbot/html/verification.php"
--          r.content_type = "text/html"
--          r:sendfile(r.filename)

            local cmd = string.format('php /opt/killbot/html/verification.php %q %q %q %q', x_forwarded_for ,remote_addr_org,user_agent, http_host)
            local handle = io.popen(cmd)
            local result = handle:read("*a")
            handle:close()
            r.content_type = "text/html"
            r:puts(result)

            log_message("ip:"  .. remote_addr_org .. " kbSession is expired : " .. kb_session .. " VP showed DONE",http_host)

            return apache2.DONE

        end
    end

    local ipParts = {}
    for part in remote_addr:gmatch("([^.]+)") do
        table.insert(ipParts, part)
    end
    table.remove(ipParts)
    remote_addr = table.concat(ipParts, ".")

--    r.headers_out["X-Debug-Remote-Addr-2"] = remote_addr

    local line = table.concat({kb_lua_script}, "")
--    local line2 = table.concat({kb2_lua_script}, "")

    local expected_hash = r.subprocess_env["KBCHECK"] or "123"
    local computed_hash = ""
    if cache[line] ~= nil then
        computed_hash = cache[line]
    end

    local now = os.time()
    if now - lastFlush > 300 then
        cache = {}
        lastFlush = now
    end

    if computed_hash == expected_hash then
        r.subprocess_env["KBCHECK_MUST_BE"] = "true"
        log_message("ip:"  .. remote_addr_org .. " cached computed_hash == expected_hash: '" .. computed_hash .. "' DECLINED",http_host)
        return apache2.DECLINED
    end

    computed_hash = modifyMd5(line)

--    r.headers_out["X-Debug-expected_hash"] = expected_hash
--    r.headers_out["X-Debug-computed_hash"] = computed_hash
--    r.headers_out["X-Debug-computed_line"] = line
--    r.headers_out["X-Debug-Res"] = "NEXT"

    if computed_hash == expected_hash then
        r.subprocess_env["KBCHECK_MUST_BE"] = "true"
        log_message("ip:"  .. remote_addr_org .. " computed computed_hash == expected_hash: " .. computed_hash .. " DECLINED",http_host)
        return apache2.DECLINED
    else
--        if line2 then computed_hash = modifyMd5(line2) end

        if computed_hash == expected_hash then
            r.subprocess_env["KBCHECK_MUST_BE"] = "true"
            log_message("ip:"  .. remote_addr_org .. " computed computed_hash == expected_hash: " .. computed_hash .. " DECLINED",http_host)
            return apache2.DECLINED
        else    
            --local handle = io.popen("php /opt/killbot/html/verification.php")
            local cmd = string.format('php /opt/killbot/html/verification.php %q %q %q %q', x_forwarded_for ,remote_addr_org, user_agent, http_host)
            local handle = io.popen(cmd)
            local result = handle:read("*a")
            handle:close()
            r.content_type = "text/html"
            r:puts(result)

            log_message("ip:"  .. remote_addr_org .. " VP showed DONE line=" .. line,http_host)

            return apache2.DONE
        end
    end
end

EOF


sudo sudo tee /opt/killbot/apache443-killbot.sh > /dev/null <<EOF
#!/bin/bash

if [ \$# -ne 8 ]; then
  echo "Usage: \$0 <domain> <main_domain> <secondary_domain> <backend_ip> <user_agent_disallowed> <wlpath> <ip_disallowed> <cdn_static> <cdn_domain> <cdn_paths> <https>"
  #exit 1
fi

domain=\$1
main_domain=\$2
secondary_domain=\$3
backend_ip=\$4

user_agent_disallowed="\$5"
wlpath="\$6"
ip_disallowed="\$7"

cdn_static=\$8
cdn_domain=\$9
cdn_paths=\${10}
https=\${11}
cdn_paths_array=()
cdn_domain_no_https=""

if [[ -n "\$cdn_paths" ]]; then
    IFS=',' read -ra cdn_paths_array <<< "\$cdn_paths"
fi

if [[ "\$cdn_static" == "2" ]] && [[ -n "\$cdn_domain" ]]; then
    cdn_domain_no_https=\$(echo "\$cdn_domain" | sed -E 's#^https?://##; s#/.*##')
fi

nginXConfigFile="/etc/nginx/sites-available/\$domain.conf"

nginXconfigContent="server {
    listen 80;
    server_name \$domain www.\$domain *.\$domain;

    # Redirect HTTP to HTTPS
    return 301 https://\\\$host\\\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name \$domain www.\$domain *.\$domain;

    include /etc/nginx/conf.d/killbot-too-many-requests.inc;

    ssl_certificate ***SSLCertificateFile***;
    ssl_certificate_key ***SSLCertificateKeyFile***;

    if (\\\$server_protocol = 'HTTP/1.3') {
        return 403;
    }

    if (\\\$request_uri ~ '^([^?]*?)/{2,}(\?.*)?\\\$') {
        return 301 \\\$scheme://\\\$host\\\$1/\\\$is_args\\\$args;
    }

    #if (\\\$args ~ .+) { return 444; }  # block if there is at least one query parameter (useful during DDoS)
    
    #if (\\\$args ~ (^|&)(param1|param2|param3)(=|&|\\\$)) { return 444; } # block if a query parameter is one of param1,param2,param3... (useful during DDoS)

    location ^~ /.well-known {

    if (\\\$kb_should_block) { return 444; }

        root /var/www/html;
        default_type text/plain;
        try_files \\\$uri =404;
        
        # Logging (optional)
        access_log /var/log/nginx/well-known.log;
        
        # Allow everyone
        allow all;
    }

    location / {

        if (\\\$kb_should_block) { return 444; }

        #    DDoS JS-cookie gate: a browser will pass, a simple bot without JS will not. Replace kb_ddos_pass with your own cookie name
        #    if (\\\$http_cookie !~* \"(^|;\s*)kb_ddos_pass=1($|;)\") {
        #        add_header Content-Type text/html;
        #        return 200 '<!doctype html><html><head><meta charset=\"utf-8\"><script>document.cookie=\"kb_ddos_pass=1; Max-Age=86400; Path=/; SameSite=Lax\"; location.reload();</script></head><body></body></html>';
        #    }

";

nginXconfigContent+="
        proxy_ssl_server_name on;
        proxy_ssl_name \\\$host;
        proxy_ssl_verify off;
";

if [  -n "\$cdn_domain" ] && [ \${#cdn_paths_array[@]} -gt 0 ]; then

nginXconfigContent+="
proxy_set_header Accept-Encoding '';

sub_filter_once off;
sub_filter_types text/html;
"

for path in "\${cdn_paths_array[@]}"; do

nginXconfigContent+="

sub_filter 'href=\"\${path}'  'href=\"\$cdn_domain\${path}';
sub_filter 'href=\"\${path:1}'  'href=\"\$cdn_domain\${path}';
sub_filter 'href=\"https://\\\$host\${path}'  'href=\"\$cdn_domain\${path}';
sub_filter 'href=\"http://\\\$host\${path}'  'href=\"\$cdn_domain\${path}';
sub_filter 'href=\"//\\\$host\${path}'  'href=\"\$cdn_domain\${path}';

sub_filter \"href='\${path}\"  \"href='\$cdn_domain\${path}\";
sub_filter \"href='\${path:1}\"  \"href='\$cdn_domain\${path}\";
sub_filter \"href='https://\\\$host\${path}\"  \"href='\$cdn_domain\${path}\";
sub_filter \"href='http://\\\$host\${path}\"  \"href='\$cdn_domain\${path}\";
sub_filter \"href='//\\\$host\${path}\"  \"href='\$cdn_domain\${path}\";

sub_filter 'src=\"\${path}'  'src=\"\$cdn_domain\${path}';
sub_filter 'src=\"\${path:1}'  'src=\"\$cdn_domain\${path}';
sub_filter 'src=\"https://\\\$host\${path}'  'src=\"\$cdn_domain\${path}';
sub_filter 'src=\"http://\\\$host\${path}'  'src=\"\$cdn_domain\${path}';
sub_filter 'src=\"//\\\$host\${path}'  'src=\"\$cdn_domain\${path}';

sub_filter \"src='\${path}\"  \"src='\$cdn_domain\${path}\";
sub_filter \"src='\${path:1}\"  \"src='\$cdn_domain\${path}\";
sub_filter \"src='https://\\\$host\${path}\"  \"src='\$cdn_domain\${path}\";
sub_filter \"src='http://\\\$host\${path}\"  \"src='\$cdn_domain\${path}\";
sub_filter \"src='//\\\$host\${path}\"  \"src='\$cdn_domain\${path}\";
"

done

fi

nginXconfigContent+="proxy_http_version 1.1;
        proxy_set_header Connection '';

        proxy_pass https://127.0.0.1:8443;
        proxy_set_header Host \\\$host;
        #proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        #proxy_set_header X-Forwarded-Proto \\\$scheme;
        #proxy_set_header X-Forwarded-Host \\\$host;
        #proxy_set_header X-Forwarded-Port \\\$server_port;

        proxy_connect_timeout 60s;
        proxy_send_timeout 3h;
        proxy_read_timeout 3h;

    }

}"

#create or rewrite
echo -e "\$nginXconfigContent" | sudo tee "\$nginXConfigFile" > /dev/null

configFile="/etc/apache2/sites-available/\$domain-killbot.conf"


configContent="<VirtualHost 127.0.0.1:8443>
    ServerName \$secondary_domain
    ***www_ssl_on***
    SSLCertificateFile ***SSLCertificateFile***
    SSLCertificateKeyFile ***SSLCertificateKeyFile***

    Redirect permanent / https://\$main_domain/
</VirtualHost>

<VirtualHost 127.0.0.1:8080>
    ServerName \$main_domain
    ServerAlias \$secondary_domain    
    ServerAlias www.\$domain
    ***SubdomainAlias***
   
    RewriteEngine On        
    RewriteCond %{HTTP_HOST} ^(\$main_domain|\$secondary_domain)\$ [NC]
    RewriteRule ^(.*)\$ https://\$main_domain%{REQUEST_URI} [R=301,L]
        
    RewriteCond %{HTTP_HOST} ^(.+)\.\$domain\$ [NC]
    RewriteRule ^(.*)\$ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>

<VirtualHost 127.0.0.1:8443>
    ServerName \$main_domain
    ServerAlias www.\$domain
    ***SubdomainAlias***

    RewriteEngine on

    SSLEngine on
    SSLCertificateFile ***SSLCertificateFile***
    SSLCertificateKeyFile ***SSLCertificateKeyFile***
    
    AllowEncodedSlashes NoDecode

    ErrorLog /var/log/apache2/\$domain.error.log
    CustomLog /var/log/apache2/\$domain.access.log combined

    # verification.php restrictions
    <Files \"/opt/killbot/html/verification.php\">
        Header set Connection \"close\"        
    </Files>

    Alias /FakeBot.php /opt/killbot/html/FakeBot.php
    <Directory /opt/killbot/html>
        <Files \"FakeBot.php\">
            Require all granted
        </Files>
        Require all denied
    </Directory>

    Alias /access_denied.html /opt/killbot/html/access_denied.html
    <Directory /opt/killbot/html>
        <Files 'access_denied.html'>
            Require all granted
        </Files>
        Require all denied
    </Directory>

    Alias /too_many_requests.html /opt/killbot/html/too_many_requests.html
    <Directory /opt/killbot/html>
        <Files 'too_many_requests.html'>
            Require all granted
        </Files>
        Require all denied
    </Directory>
   
    <Directory '/var/www/html/.well-known'>
        Options None
        AllowOverride None
        Require all granted
    </Directory>

#    RewriteCond %{REQUEST_URI} ^/verification\.php [NC]
#    RewriteCond %{REQUEST_METHOD} POST
#    RewriteRule ^(.*)$ /$1 [R=302,L]

    SetEnvIf X-Forwarded-For \"^([0-9\.]+)\" REAL_REMOTE_ADDR=\\\$1

    RewriteCond %{ENV:REAL_REMOTE_ADDR} ^$
    RewriteRule .* - [E=REAL_REMOTE_ADDR:%{REMOTE_ADDR}]

    RewriteCond %{HTTP_COOKIE} (^|;\s*)kbCheck=([^;]+) [NC]
    RewriteRule ^ - [E=KBCHECK:%2]

    RewriteCond %{HTTP_COOKIE} (^|;\s*)kbSession=([^;]+) [NC]
    RewriteRule ^ - [E=KBSESSION:%2]

    RewriteCond %{ENV:KBCHECK} ^Expired\$
    RewriteRule ^(.*)\$ /opt/killbot/html/Expired.html [L]

    RewriteRule ^ - [E=KBCHECK_MUST_BE:true]
    LuaHookFixups /opt/killbot/lua/\$domain.lua handle
"
    
if [[ "\$https" == "https" ]]; then 
    configContent+="
            SSLProxyEngine On 
            SSLProxyCheckPeerCN Off
            SSLProxyCheckPeerName Off
            SSLProxyCheckPeerExpire Off
    "
fi

configContent+="
        ProxyPass /FakeBot.php !
        ProxyPass /opt/killbot/html/FakeBot.php !

        ProxyPass /access_denied.html !
        ProxyPass /opt/killbot/html/access_denied.html !

        ProxyPass /too_many_requests.html !
        ProxyPass /opt/killbot/html/too_many_requests.html !

        ProxyPass /.well-known !
        ProxyPass /var/www/html/.well-known !
        
        # set X-Real-IP if not exist
        RequestHeader setIfEmpty X-Real-IP \"%{REAL_REMOTE_ADDR}e\"

        # Set X-Forwarded-For
        #RewriteRule .* - [E=SERVER_REMOTE_ADDR:%{REMOTE_ADDR}]
        #RequestHeader append X-Forwarded-For \"%{SERVER_REMOTE_ADDR}e\"

        Header unset X-Frame-Options

        #RequestHeader set Host \"\$main_domain\"
"       

if [[ -n "\$cdn_domain_no_https" ]]; then
    # Check CDN domain availability
    cdn_check_url="\$https://\${cdn_domain_no_https}/"
    http_code=\$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -H "Host: \$main_domain" "\$cdn_check_url")
    if [ "\$http_code" -ne 200 ]; then
    configContent+="
            #ProxyPreserveHost On
            ProxyPreserveHost Off
"        
    else        
        configContent+="
            ProxyPreserveHost On            
            #ProxyPreserveHost Off
"                    
    fi
        
else
    configContent+="
        ProxyPreserveHost On        
        #ProxyPreserveHost Off
"
fi

if [[ -n "\$cdn_domain_no_https" ]]; then

    configContent+="        
            ProxyPass /robots.txt \$https://\$backend_ip/robots.txt
            ProxyPassReverse /robots.txt \$https://\$backend_ip/robots.txt

            ProxyPass / \$https://\$cdn_domain_no_https/
            ProxyPassReverse / \$https://\$cdn_domain_no_https/
    "
else
    configContent+="        
            ProxyPass / \$https://\$backend_ip/ nocanon
            ProxyPassReverse / \$https://\$backend_ip/
    "
fi

configContent+="        
    <Directory /opt/killbot/html>
        Options Indexes FollowSymLinks MultiViews
        AllowOverride All
        Require all granted

        Order allow,deny
        Allow from all

        Header set Cache-Control \"no-cache, no-store, must-revalidate\"
        Header set Pragma \"no-cache\"
        Header set Expires 0
    </Directory>

</VirtualHost>"

echo -e "\$configContent" | sudo tee "\$configFile" > /dev/null

echo "Configuration for \$domain has been created."
EOF

sudo chmod +x /opt/killbot/apache443-killbot.sh


sudo tee /opt/killbot/apache80_letsencrypt_test.sh > /dev/null <<EOF
#!/bin/bash

if [ \$# -ne 2 ]; then
  echo "Usage: \$0 <domain> <backend_ip>"
  exit 1
fi

domain=\$1
backend_ip=\$2

nginXConfigFile="/etc/nginx/sites-available/\$domain.conf"

nginXconfigContent="
server {    
    listen 80;
    listen 443 ssl http2;
    server_name \$domain www.\$domain *.\$domain;

    include /etc/nginx/conf.d/killbot-too-many-requests.inc;

    if (\\\$server_protocol = "HTTP/1.3") {
        return 403;
    }

    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    if (\\\$request_uri ~ '^([^?]*?)/{2,}(\?.*)?\\\$') {
        return 301 \\\$scheme://\\\$host\\\$1/\\\$is_args\\\$args;
    }

    location ^~ /.well-known {

        if (\\\$kb_should_block) { return 444; }

        root /var/www/html;
        default_type text/plain;
        try_files \\\$uri =404;
        
        # Logging (optional)
        access_log /var/log/nginx/well-known.log;
        
        # Allow everyone
        allow all;
    }

    location / {

        if (\\\$kb_should_block) { return 444; }

        proxy_ssl_server_name on;
        proxy_ssl_name \\\$host;
        proxy_ssl_verify off;

        proxy_http_version 1.1;
        proxy_set_header Connection '';

        proxy_pass https://127.0.0.1:8443;
        proxy_set_header Host \\\$host;
        #proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        #proxy_set_header X-Forwarded-Proto \\\$scheme;
        #proxy_set_header X-Forwarded-Host \\\$host;
        #proxy_set_header X-Forwarded-Port \\\$server_port;

        proxy_connect_timeout 60s;
        proxy_send_timeout 3h;
        proxy_read_timeout 3h;

        include /etc/nginx/conf-proxy-custom/*.conf;
        include /etc/nginx/conf-proxy--site/\$domain.*.conf;
    } 

    include /etc/nginx/conf-custom/*.conf;
    include /etc/nginx/conf-custom-site/\$domain.*.conf;
   
}"

#create or rewrite
echo -e "\$nginXconfigContent" | sudo tee "\$nginXConfigFile" > /dev/null

configFile="/etc/apache2/sites-available/\$domain-le.conf"

configContent="<VirtualHost 127.0.0.1:8080>
   
    ServerName \$domain
    ServerAlias www.\$domain
    DocumentRoot /var/www/html

    Alias /.well-known /var/www/html/.well-known
    <Directory "/var/www/html/.well-known">
        Options None
        AllowOverride None
        Require all granted
    </Directory>

    RewriteEngine On

    RewriteCond %{REQUEST_URI} !^/kb.php$
    RewriteCond %{REQUEST_URI} !^/le_receive_cert.php$
    RewriteCond %{REQUEST_URI} !^/empty.php$
    RewriteCond %{REQUEST_URI} !^/le_custom_server/request.php$
    RewriteCond %{REQUEST_URI} !^/\.well-known
    RewriteRule ^ /empty.php [L]

    ErrorLog /var/log/apache2/\$domain-le.error.log
    CustomLog /var/log/apache2/\$domain-le.access.log combined
</VirtualHost>

<VirtualHost 127.0.0.1:8443>
    ServerName \$domain
    ServerAlias www.\$domain
    DocumentRoot /var/www/html
   
    Alias /.well-known /var/www/html/.well-known
    <Directory "/var/www/html/.well-known">
        Options None
        AllowOverride None
        Require all granted
    </Directory>

    RewriteEngine On

    RewriteCond %{REQUEST_URI} !^/kb.php$
    RewriteCond %{REQUEST_URI} !^/le_receive_cert.php$
    RewriteCond %{REQUEST_URI} !^/empty.php$
    RewriteCond %{REQUEST_URI} !^/le_custom_server/request.php$
    RewriteCond %{REQUEST_URI} !^/\.well-known
    RewriteRule ^ /empty.php [L]

    
    # SSL Configuration with self-signed certificate
    SSLEngine on
    SSLCertificateFile      /etc/ssl/certs/ssl-cert-snakeoil.pem
    SSLCertificateKeyFile   /etc/ssl/private/ssl-cert-snakeoil.key

    ErrorLog /var/log/apache2/\$domain-le-ssl.error.log
    CustomLog /var/log/apache2/\$domain-le-ssl.access.log combined
</VirtualHost>
"

if [ ! -f "\$configFile" ]; then
    #Create file if not exist
    echo -e "\$configContent" | sudo tee "\$configFile" > /dev/null
fi

echo "Configuration for \$domain-le has been created."
EOF
sudo chmod +x /opt/killbot/apache80_letsencrypt_test.sh      



sudo tee /opt/killbot/apache443.sh > /dev/null <<EOF
#!/bin/bash

if [ \$# -ne 5 ]; then
  echo "Usage: \$0 <domain> <main_domain> <secondary_domain> <backend_ip> <folder>"
  exit 1
fi

domain=\$1
main_domain=\$2
secondary_domain=\$3
backend_ip=\$4
https=\$5


configFile="/etc/apache2/sites-available/\$domain.conf"

configContent="<VirtualHost 127.0.0.1:8443>
    ServerName \$secondary_domain

    ***www_ssl_on***
    SSLCertificateFile ***SSLCertificateFile***
    SSLCertificateKeyFile ***SSLCertificateKeyFile***

    Redirect permanent / https://\$main_domain/
</VirtualHost>

<VirtualHost 127.0.0.1:8080>
    ServerName \$main_domain
    ServerAlias \$secondary_domain    
    ServerAlias www.\$domain
    ***SubdomainAlias***
   
    RewriteEngine On        
    RewriteCond %{HTTP_HOST} ^(\$main_domain|\$secondary_domain)\$ [NC]
    RewriteRule ^(.*)\$ https://\$main_domain%{REQUEST_URI} [R=301,L]
        
    RewriteCond %{HTTP_HOST} ^(.+)\.\$domain\$ [NC]
    RewriteRule ^(.*)\$ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>

<VirtualHost 127.0.0.1:8443>
    ServerName \$main_domain
    ServerAlias \$secondary_domain
    ServerAlias www.\$domain
    ***SubdomainAlias***

    ErrorLog \\\${APACHE_LOG_DIR}/error.log
    CustomLog \\\${APACHE_LOG_DIR}/access.log combined

    SSLEngine on
    SSLCertificateFile ***SSLCertificateFile***
    SSLCertificateKeyFile ***SSLCertificateKeyFile***

    AllowEncodedSlashes NoDecode

    RewriteEngine on

    SetEnvIf X-Forwarded-For \"^([0-9\.]+)\" REAL_REMOTE_ADDR=$1

    RewriteCond %{ENV:REAL_REMOTE_ADDR} ^$
    RewriteRule .* - [E=REAL_REMOTE_ADDR:%{REMOTE_ADDR}]

    Alias /access_denied.html /opt/killbot/html/access_denied.html
    <Directory /opt/killbot/html>
        <Files "access_denied.html">
            Require all granted
        </Files>
        Require all denied
    </Directory>

    Alias /too_many_requests.html /opt/killbot/html/too_many_requests.html
    <Directory /opt/killbot/html>
        <Files "too_many_requests.html">
            Require all granted
        </Files>
        Require all denied
    </Directory>

    Alias /.well-known /var/www/html/.well-known
    <Directory "/var/www/html/.well-known">
        Options None
        AllowOverride None
        Require all granted
    </Directory>

    #Define PROXY_ENABLE

    <IfDefine PROXY_ENABLE>
        ProxyPreserveHost On
"
if [[ "\$https" == "https" ]]; then 
        configContent+="
        SSLProxyEngine On 
        SSLProxyCheckPeerCN Off
        SSLProxyCheckPeerName Off
        SSLProxyCheckPeerExpire Off
"
fi

configContent+="
        ProxyPass /.well-known !
        ProxyPass /var/www/html/.well-known !

        ProxyPass /access_denied.html !
        ProxyPass /opt/killbot/html/access_denied.html !

        ProxyPass /too_many_requests.html !
        ProxyPass /opt/killbot/html/too_many_requests.html !
       
        # set X-Real-IP if not exist
        RequestHeader setIfEmpty X-Real-IP "%{REAL_REMOTE_ADDR}e"

        # Set X-Forwarded-For
        #RewriteRule .* - [E=SERVER_REMOTE_ADDR:%{REMOTE_ADDR}]
        #RequestHeader append X-Forwarded-For "%{SERVER_REMOTE_ADDR}e"

        Header unset X-Frame-Options

        #RequestHeader set Host "\$main_domain"

        ProxyPass / \$https://\$backend_ip/ nocanon
        ProxyPassReverse / \$https://\$backend_ip/


    </IfDefine>
    
</VirtualHost>"


#create or rewrite
echo -e "\$configContent" | sudo tee "\$configFile" > /dev/null

echo "Configuration for \$domain has been created."
EOF

sudo chmod +x /opt/killbot/apache443.sh

sudo sudo tee /etc/init.d/kb > /dev/null <<EOF
#!/bin/bash
#
# Script for managing killbot
#

# Path to Apache configurations directory
APACHE_CONF_DIR="/etc/apache2/sites-available"
# Path to killbot installation script
KILLBOT_INSTALL_SCRIPT="/opt/killbot/install.sh"
# Path to killbot cert delete script
KILLBOT_CERT_DELETE_SCRIPT="/opt/killbot/cert_delete.sh"
# Path to killbot settings
SETTINGS_DIR="/opt/killbot/settings"
# Prefix for nginx reverse-proxy configs (loaded before *.domain)
REVERSE_PROXY_NGINX_PREFIX="000-"

# Check for root privileges
if [ "\$(id -u)" != "0" ]; then
   echo "This script must be run as root." 1>&2
   exit 1
fi

# Function to check Apache and Nginx configuration
check_apache_config() {
    # Checking Apache configuration for errors
    apache2ctl configtest > /dev/null 2>&1
    if [ \$? -ne 0 ]; then
        echo "Apache configuration test failed."
        exit 1
    fi
    
    # Checking Nginx configuration for errors
    nginx -t > /dev/null 2>&1
    if [ \$? -ne 0 ]; then
        echo "Nginx configuration test failed."
        exit 1
    fi
}

# Function to delete killbot certificate
cert_del() {
    local domain=\$1

    if [ -z "\$domain" ]; then
        echo "Usage: \$0 cert_del domain"
        exit 1
    fi

    if [ ! -x "\$KILLBOT_CERT_DELETE_SCRIPT" ]; then
        echo "Cert delete script not found or not executable: \$KILLBOT_CERT_DELETE_SCRIPT"
        exit 1
    fi

    "\$KILLBOT_CERT_DELETE_SCRIPT" "\$domain"
    echo "Certificate deleted for domain \$domain."
}

# Path to killbot_revers for domain (settings/DOMAIN or legacy /opt/killbot/DOMAIN/)
get_killbot_revers_file() {
    local domain=\$1

    if [ -f "\${SETTINGS_DIR}/\${domain}/killbot_revers" ]; then
        echo "\${SETTINGS_DIR}/\${domain}/killbot_revers"
    elif [ -f "/opt/killbot/\${domain}/killbot_revers" ]; then
        echo "/opt/killbot/\${domain}/killbot_revers"
    fi
}

reverse_proxy_nginx_conf_name() {
    local proxy="\$1"
    echo "\${REVERSE_PROXY_NGINX_PREFIX}\${proxy}.conf"
}

# Disable nginx reverse-proxy vhosts listed in killbot_revers (no-op if file missing)
disable_reverse_proxy_nginx() {
    local domain=\$1
    local revers_file proxy line conf

    revers_file=\$(get_killbot_revers_file "\$domain")
    [ -z "\$revers_file" ] && return 0

    while IFS= read -r line || [ -n "\$line" ]; do
        line="\${line%%#*}"
        line="\$(echo "\$line" | tr -d '[:space:]')"
        [ -z "\$line" ] && continue

        if [[ "\$line" == *:* ]]; then
            proxy="\${line%%:*}"
        else
            proxy="\$line"
        fi

        proxy="\${proxy#https://}"
        proxy="\${proxy#http://}"
        proxy="\${proxy%%/*}"
        [ -z "\$proxy" ] && continue

        conf="\$(reverse_proxy_nginx_conf_name "\$proxy")"
        rm -f "/etc/nginx/sites-enabled/\${conf}"
        rm -f "/etc/nginx/sites-enabled/\${proxy}.conf"
    done < "\$revers_file"
}

# Enable nginx reverse-proxy vhosts listed in killbot_revers (no-op if file missing)
enable_reverse_proxy_nginx() {
    local domain=\$1
    local revers_file proxy line conf avail

    revers_file=\$(get_killbot_revers_file "\$domain")
    [ -z "\$revers_file" ] && return 0

    while IFS= read -r line || [ -n "\$line" ]; do
        line="\${line%%#*}"
        line="\$(echo "\$line" | tr -d '[:space:]')"
        [ -z "\$line" ] && continue

        if [[ "\$line" == *:* ]]; then
            proxy="\${line%%:*}"
        else
            proxy="\$line"
        fi

        proxy="\${proxy#https://}"
        proxy="\${proxy#http://}"
        proxy="\${proxy%%/*}"
        [ -z "\$proxy" ] && continue

        conf="\$(reverse_proxy_nginx_conf_name "\$proxy")"
        avail="/etc/nginx/sites-available/\${conf}"
        [ -f "\$avail" ] || continue
        rm -f "/etc/nginx/sites-enabled/\${proxy}.conf"
        ln -sf "\$avail" "/etc/nginx/sites-enabled/\${conf}"
    done < "\$revers_file"
}

# Remove nginx reverse-proxy configs (sites-available + sites-enabled)
purge_reverse_proxy_nginx() {
    local domain=\$1
    local revers_file proxy line conf

    revers_file=\$(get_killbot_revers_file "\$domain")
    [ -z "\$revers_file" ] && return 0

    while IFS= read -r line || [ -n "\$line" ]; do
        line="\${line%%#*}"
        line="\$(echo "\$line" | tr -d '[:space:]')"
        [ -z "\$line" ] && continue

        if [[ "\$line" == *:* ]]; then
            proxy="\${line%%:*}"
        else
            proxy="\$line"
        fi

        proxy="\${proxy#https://}"
        proxy="\${proxy#http://}"
        proxy="\${proxy%%/*}"
        [ -z "\$proxy" ] && continue

        conf="\$(reverse_proxy_nginx_conf_name "\$proxy")"
        rm -f "/etc/nginx/sites-enabled/\${conf}" "/etc/nginx/sites-available/\${conf}"
        rm -f "/etc/nginx/sites-enabled/\${proxy}.conf" "/etc/nginx/sites-available/\${proxy}.conf"
    done < "\$revers_file"
}

disable_domain_sites() {
    local domain=\$1
    local standard_conf="\$domain.conf"
    local killbot_conf="\$domain-killbot.conf"

    a2dissite "\$standard_conf" > /dev/null 2>&1
    a2dissite "\$killbot_conf" > /dev/null 2>&1
    rm -f "/etc/nginx/sites-enabled/\${domain}.conf"
    rm -f "/etc/nginx/sites-enabled/\${domain}-killbot.conf"
    disable_reverse_proxy_nginx "\$domain"
}

# Function to disable apache sites for domain and reload apache
# kb a2dissite {domain.ru}
a2dissite_domain() {
    local domain=\$1
    local standard_conf="\$domain.conf"
    local killbot_conf="\$domain-killbot.conf"

    # check syntax first
    check_apache_config

    disable_domain_sites "\$domain"

    # Reload Apache
    service apache2 reload
    service nginx reload
    echo "Apache and nginx disabled for domain \$domain (both \$standard_conf and \$killbot_conf). Apache reloaded."
}

# Function to enable killbot screen configuration
ensite() {
    local domain=\$1
    local opt=\$2
    local killbot_conf="\$domain-killbot.conf"
    local standard_conf="\$domain.conf"    

    if [ ! -f "\$APACHE_CONF_DIR/\$killbot_conf" ]; then
        printf  "Configuration \$killbot_conf not found.\nInstall killbot configuration first.\nUsage:\n -reverce proxy case: kb install -d {domain} -e {email} -ip {domain_backend_ip}\n"
        exit 1
    fi

    # Disable the standard configuration
    a2dissite "\$standard_conf" > /dev/null 2>&1

    # Enable the killbot verification page configuration
    a2ensite "\$killbot_conf" > /dev/null 2>&1

    rm -f "/etc/nginx/sites-enabled/\$standard_conf.conf"
    ln -sf "/etc/nginx/sites-available/\$standard_conf" "/etc/nginx/sites-enabled/\$standard_conf"

    enable_reverse_proxy_nginx "\$domain"

    # Enable the killbot screen configuration
    echo "Killbot verification page for domain \$domain has been enabled."
    
    check_apache_config

    # Restart Apache to apply changes
    service apache2 reload
    service nginx reload
    
}

# Function to disable killbot screen configuration
dissite() {
    local domain=\$1
    local killbot_conf="\$domain-killbot.conf"
    local standard_conf="\$domain.conf"
    
    if [ ! -f "\$APACHE_CONF_DIR/\$standard_conf" ]; then        
        printf  "Configuration \$standard_conf not found.\nInstall killbot configuration first.\nUsage:\n -if website in /var/www/html/domain folder): kb install domain email\n -proxy case (IP - website backend ip): kb install domain email ip\n"
        exit 1
    fi

    # Disable the killbot verification page configuration
    a2dissite "\$killbot_conf" > /dev/null 2>&1    

    # Enable the standard configuration
    a2ensite "\$standard_conf" > /dev/null 2>&1
    ln -sf /etc/nginx/sites-available/\$standard_conf /etc/nginx/sites-enabled/

    disable_reverse_proxy_nginx "\$domain"

    check_apache_config

    # Restart Apache to apply changes
    service apache2 reload
    service nginx reload
    echo "Killbot screen for domain \$domain has been disabled."
}

# Function to reload apache2
reload() {
    
    check_apache_config

    # Restart Apache to apply changes
    service apache2 reload
    service nginx reload
    echo "Apache2 reloaded. Nginx reload."
}

# Function to install killbot screen configuration
install() {    

    if [ ! -x "\$KILLBOT_INSTALL_SCRIPT" ]; then
        echo "Killbot installation script not found or not executable."
        exit 1
    fi

    # Run the installation script
    "\$KILLBOT_INSTALL_SCRIPT" "\$1" "\$2" "\$3" "\$4" "\$5" "\$6" "\$7" "\$8" "\$9" "\${10}" "\${11}" "\${12}" "\${13}" "\${14}" "\${15}" "\${16}" "\${17}" "\${18}" "\${19}" "\${20}" "\${21}" "\${22}" "\${23}" "\${24}" "\${25}" "\${26}" "\${27}" "\${28}" "\${29}" "\${30}"
    #echo "Killbot configuration with verification page for domain \$domain has been installed."
}

# kb remove {domain.ru} — fully remove the domain
remove_domain() {
    local domain=\$1

    if [ -z "\$domain" ]; then
        echo "Usage: \$0 remove domain"
        exit 1
    fi

    if [[ "\$domain" == *"/"* || "\$domain" == *".."* ]]; then
        echo "Invalid domain: \$domain"
        exit 1
    fi

    disable_domain_sites "\$domain"
    purge_reverse_proxy_nginx "\$domain"

    if command -v certbot >/dev/null 2>&1; then
        certbot delete --cert-name "\$domain" --non-interactive 2>/dev/null || true
    fi

    if [ -d "\${SETTINGS_DIR}/\${domain}" ]; then
        rm -rf "\${SETTINGS_DIR}/\${domain}"
        echo "Removed: \${SETTINGS_DIR}/\${domain}"
    fi

    if [ -f "/opt/killbot/lua/\${domain}.lua" ]; then
        rm -f "/opt/killbot/lua/\${domain}.lua"
        echo "Removed: /opt/killbot/lua/\${domain}.lua"
    fi

    if [ -d "/opt/killbot/ssl/\${domain}" ]; then
        rm -rf "/opt/killbot/ssl/\${domain}"
        echo "Removed: /opt/killbot/ssl/\${domain}"
    fi

    if apache2ctl configtest >/dev/null 2>&1; then
        service apache2 reload
    fi

    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
        service nginx reload
    fi

    echo "Domain \$domain removed."
}

# Command handling
case "\$1" in
    reload)
        reload
        ;;
    ensite)
        if [ -z "\$2" ]; then
            echo "Usage: \$0 ensite domain"
            exit 1
        fi
        
        ensite "\$2" "\$3"
        ;;
    dissite)
        if [ -z "\$2" ]; then
            echo "Usage: \$0 dissite domain"
            exit 1
        fi
        dissite "\$2"
        ;;
    cert_del)
        if [ -z "\$2" ]; then
            echo "Usage: \$0 cert_del domain"
            exit 1
        fi
        cert_del "\$2"
        ;;
    a2dissite)
        if [ -z "\$2" ]; then
            echo "Usage: \$0 a2dissite domain"
            exit 1
        fi
        a2dissite_domain "\$2"
        ;;
    remove)
        if [ -z "\$2" ]; then
            echo "Usage: \$0 remove domain"
            exit 1
        fi
        remove_domain "\$2"
        ;;
    install)
        
        install "\$2" "\$3" "\$4" "\$5" "\$6" "\$7" "\$8" "\$9" "\${10}" "\${11}" "\${12}" "\${13}" "\${14}" "\${15}" "\${16}" "\${17}" "\${18}" "\${19}" "\${20}" "\${21}" "\${22}" "\${23}" "\${24}" "\${25}" "\${26}" "\${27}" "\${28}" "\${29}" "\${30}"
        ;;
    *)
        echo "Usage: kb {ensite|dissite|a2dissite|cert_del|remove|install|reload} domain"
        exit 1
        ;;
esac

exit 0
EOF

sudo chmod +x /etc/init.d/kb

if [ ! -L "/usr/local/bin/kb" ]; then
    sudo ln -sf /etc/init.d/kb /usr/local/bin/kb
fi

sudo tee /opt/killbot/install.sh > /dev/null <<EOF
#!/bin/bash

declare email=""
declare token=""
declare backend_ip=""
declare folder=""
declare domain=""
declare www=-1
declare le="1"
declare wlip=\$(grep -vE '^\$' /opt/killbot/wl-ip | paste -sd ",")
declare wlua=\$(grep -vE '^\$' /opt/killbot/wl-ua | paste -sd ",")
declare wlpath=\$(grep -vE '^\$' /opt/killbot/wl-path | paste -sd ",")
declare SSLCertificateFile=""
declare SSLCertificateKeyFile=""
declare cdn_domain=""
declare cdn_paths=""
declare cdn_static=""
declare https="https"

DNS_SERVERS=("77.88.8.8" "8.8.8.8")  # yandex, Google
RANDOM_INDEX=\$(( \${#DNS_SERVERS[@]} > 0 ? RANDOM % \${#DNS_SERVERS[@]} : 0 ))
DNS_LE_SERVER="\${DNS_SERVERS[\$RANDOM_INDEX]}"
echo "DNS server: \$DNS_LE_SERVER"

declare DNSServer="\$DNS_LE_SERVER"

# DNS API configuration for wildcard SSL certificates
declare use_sub_domains="0"
declare api_env_content=""
declare dns_provider=""

while [[ "\$#" -gt 0 ]]; do
    if [[ -z "\$1" ]]; then
        break
    fi
    case "\$1" in
        -e)
            email="\$2"; shift 2;;
        -t)
            token="\$2"; shift 2;;
        -ip)
            backend_ip="\$2"; shift 2;;
        -f)
            folder="\$2"; shift 2;;
        -cdn)
            cdn_domain="\$2"; shift 2;;
        -cdnp)
            cdn_paths="\$2"; shift 2;;
        -cdns)
            cdn_static="\$2"; shift 2;;
        -d)
            domain="\$2"; shift 2;;
        -wlip)
            wlip="\$2"; shift 2;;
        -https)
            https="\$2"; shift 2;;
        -wlua)
            wlua="\$2"; shift 2;;
        -wlpath)
            wlpath="\$2"; shift 2;;
        -le)
            le="\$2"; shift 2;;
        -www)
            www="\$2"; shift 2;;
        # DNS API configuration
        -use_sub_domains)
            use_sub_domains="\$2"; shift 2;;
        -api_env_content)
            api_env_content="\$2"; shift 2;;
        -dns_provider)
            dns_provider="\$2"; shift 2;;
        *)
            trimmed="\$(echo -n "\$1" | xargs)"
            [[ -n "\$trimmed" ]] && { echo "Unknown arg: '\$1'"; exit 1; } || shift 1
            ;;
    esac
done

if [[ -z "\$email" && -z "\$token" ]]; then
    echo "Error: argument email (-e) or token (-t) is required" >&2
    exit 1
fi

if [[ -z "\$backend_ip" && -z "\$folder" ]]; then
    echo "Error: argument ip (-ip) or folder (-f) is required" >&2
    exit 1
fi

if [[ -z "\$domain" ]]; then
    echo "Error: argument domain (-d) is required" >&2
    exit 1
fi

if [[ "\$domain" =~ ^https?:// ]]; then
  echo "Error: The domain should not contain http:// or https://. Enter only the website domain (without http(s))"
fi

echo "\$(date '+%F %T') install.sh pid=\$\$ ppid=\$PPID parent=[\$(ps -o args= -p \$PPID 2>/dev/null)] argv=[\$*]" >> /var/log/killbot/install_debug.log

#check if www not set
if [ "\$www" -eq -1 ]; then
    if [[ \$domain == www.* ]]; then
        www=1    
    else
        www=0        
    fi
fi

domain_without_www=\${domain#www.}
domain_with_www="www.\$domain_without_www"

FILE1="/etc/apache2/sites-enabled/\$domain_without_www-killbot.conf"
FILE2="/etc/apache2/sites-enabled/\$domain_without_www.conf"
FILE3="/etc/nginx/sites-enabled/\$domain_without_www.conf"

get_apache_hash() {
    H1=\$(md5sum "\$FILE1" 2>/dev/null | awk '{print \$1}' || echo "\$FILE1")
    H2=\$(md5sum "\$FILE2" 2>/dev/null | awk '{print \$1}' || echo "\$FILE2")
    echo "\${H1}\${H2}" | md5sum | awk '{print \$1}'
}

get_nginx_hash() {
    md5sum "\$FILE3" 2>/dev/null | awk '{print \$1}' || echo "\$FILE3"
}

# Reload or start a systemd service; retry up to 3 times with a short pause.
kb_systemctl_retry() {
    local action="\$1"
    local service="\$2"
    local attempt
    for attempt in 1 2 3; do
        if timeout 15 systemctl "\$action" "\$service"; then
            return 0
        fi
        echo "Warning: \$service \$action failed (attempt \$attempt/3)"
        if [ "\$attempt" -lt 3 ]; then
            sleep 2
        fi
    done
    echo "Error: \$service \$action failed"
    return 1
}

CURRENT_APACHE_HASH=\$(get_apache_hash)
CURRENT_NGINX_HASH=\$(get_nginx_hash)



sudo mkdir -p /etc/apache2/ssl
cd /etc/apache2/ssl

certPath="/etc/apache2/ssl/\$domain_without_www-selfsigned.crt"

if [[ ! -f "\$certPath" ]]; then
    sudo openssl req -x509 -nodes -days 6650 -newkey rsa:2048 \
        -keyout "\$domain_without_www-selfsigned.key" \
        -out "\$domain_without_www-selfsigned.crt" \
        -subj "/C=RU/ST=Moscow/L=Moscow/O=KillBot/OU=Killbot/CN=\$domain_without_www/emailAddress=\$email" \
        -addext "subjectAltName = DNS:\$domain_without_www, DNS:*.\$domain_without_www"
fi

SSLCertificateFile="/etc/apache2/ssl/\$domain_without_www-selfsigned.crt"
SSLCertificateKeyFile="/etc/apache2/ssl/\$domain_without_www-selfsigned.key"
#self-signed cert by default

server_config_error=0

SERVER_IP=\$(curl -s http://checkip.amazonaws.com)

# check if port 443 is opened
output=\$(curl -v --connect-timeout 5 --max-time 10 --insecure https://\$backend_ip:443 2>&1)

if echo "\$output" | grep -q "Connected to"; then
    echo "Port 443 on the \$backend_ip server is opened"
else
    echo "ERROR: Port 443 is closed for \$backend_ip. The KillBot server has no access to the website server. Please open port 443 on your website server (\$backend_ip) for the KillBot server (\$SERVER_IP)."
    server_config_error=1
fi

http_code=\$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 5 --max-time 10 \
  --insecure \
  --resolve \$domain:443:\$backend_ip \
  https://\$domain)

if [ "\$server_config_error" -eq 0 ] && [[ "\$http_code" =~ ^(200|301|302)$ ]]; then

    echo "Domain \$domain correctly points to \$backend_ip (resolve check OK)"

elif [ "\$server_config_error" -eq 0 ]; then
    # fallback №1
    http_code=\$(curl -s -o /dev/null -w "%{http_code}" \
      --connect-timeout 5 --max-time 10 \
      --insecure \
      -H "Host: \$domain" \
      https://\$backend_ip/)

    if [ "\$server_config_error" -eq 0 ] && [[ "\$http_code" =~ ^(200|301|302)$ ]]; then

        echo "Domain \$domain works on \$backend_ip (Host header fallback, possible SNI/SSL issue)"

    else
        # fallback №2 (HTTP)
        http_code=\$(curl -s -o /dev/null -w "%{http_code}" \
          --connect-timeout 5 --max-time 10 \
          -H "Host: \$domain" \
          http://\$backend_ip/)

        if [ "\$server_config_error" -eq 0 ] && [[ "\$http_code" =~ ^(200|301|302)$ ]]; then

            echo "Domain \$domain works on \$backend_ip via HTTP (HTTPS may be misconfigured)"

        else

            if [[ "\$http_code" == "000" ]]; then
                echo "Domain \$domain is NOT reachable on \$backend_ip (no connection)"
            else
                echo echo "Domain \$domain is NOT configured on \$backend_ip (possible wrong IP address or missing virtual host)"
            fi

            server_config_error=1
        fi
    fi
fi

if [ "\$server_config_error" -eq 1 ]; then

    SOURCE="/etc/nginx/sites-available/default"
    TARGET="/etc/nginx/sites-available/\$domain_without_www.conf"
    LINK="/etc/nginx/sites-enabled/\$domain_without_www.conf"

    if [ ! -f "\$TARGET" ]; then
        cp -f "\$SOURCE" "\$TARGET" || { echo "Error copy sites-available/default to /etc/nginx/sites-available/\$domain_without_www.conf"; exit 1; }

        sed -i "s/server_name _;/server_name \$domain_without_www *.\$domain_without_www;/g" "\$TARGET"
        

        sed -i "s/listen 80 default_server;/listen 80;/g" "\$TARGET"
        sed -i "s/listen 443 ssl default_server;/listen 443 ssl;/g" "\$TARGET"

        sed -i "s|ssl_certificate      /etc/ssl/certs/ssl-cert-snakeoil.pem;|ssl_certificate \$SSLCertificateFile;|g" "\$TARGET"
        sed -i "s|ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;|ssl_certificate_key \$SSLCertificateKeyFile;|g" "\$TARGET"
    fi

    # Enable the site
    ln -sf "\$TARGET" "\$LINK" || true

    nginx_check=\$(sudo nginx -t 2>&1)

    if echo "\$nginx_check" | grep -q "test is successful"; then
        echo "Nginx configuration for \$domain_without_www is correct."
    else
        echo "Nginx configuration error for \$domain_without_www: \$nginx_check"
        exit 1
    fi

    # Validate and reload
    nginx -t && systemctl reload nginx
    if [ \$? -eq 0 ]; then
        echo "Domain \$domain_without_www is set to default config"
    else
        echo "Error in nginx configuration"
        rm -f "\$LINK" "\$TARGET"
        exit 1
    fi

    exit 1
fi

if [ -z "\$folder" ]; then
    folder="/var/www/html/\$domain_without_www"
fi


sudo mkdir -p /var/log/apache2/
sudo chown -R www-data:www-data /var/log/apache2/
sudo chmod -R 755 /var/log/apache2/

ip_without_www_list=\$(dig @"\$DNSServer" +short "\$domain_without_www" A)
ip_with_www_list=\$(dig @"\$DNSServer" +short "\$domain_with_www" A)
resolved_ips=\$(dig @"\$DNSServer" +short "\$domain" A)

#echo "Public server IP: \$SERVER_IP"

certPath="/etc/letsencrypt/live/\$domain_without_www/fullchain.pem"

if [[ "\$le" -ne 0 && ! -f "/opt/killbot/ssl/\$domain_without_www/fullchain.pem" ]]; then
    # Check that SERVER_IP is present in at least one IP list
    if ! echo "\$resolved_ips" | grep -Fxq "\$SERVER_IP" && \
       ! echo "\$ip_without_www_list" | grep -Fxq "\$SERVER_IP" && \
       ! echo "\$ip_with_www_list" | grep -Fxq "\$SERVER_IP"; then
        echo "Error: Wait until at least one A record of the domain \$domain points to \$SERVER_IP"

        SOURCE="/etc/nginx/sites-available/default"
        TARGET="/etc/nginx/sites-available/\$domain_without_www.conf"
        LINK="/etc/nginx/sites-enabled/\$domain_without_www.conf"

        cp -f "\$SOURCE" "\$TARGET" || { echo "Error copy sites-available/default to /nginx/sites-available/DOMAIN"; exit 1; }
        sed -i "s/server_name _;/server_name \$domain;/g" "\$TARGET"

        sed -i "s/listen 80 default_server;/listen 80;/g" "\$TARGET"
        sed -i "s/listen 443 ssl default_server;/listen 443 ssl;/g" "\$TARGET"

        sed -i "s|ssl_certificate      /etc/ssl/certs/ssl-cert-snakeoil.pem;|ssl_certificate \$SSLCertificateFile;|g" "\$TARGET"
        sed -i "s|ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;|ssl_certificate_key \$SSLCertificateKeyFile;|g" "\$TARGET"

        # Enable the site
        ln -sf "\$TARGET" "\$LINK"

        nginx_check=\$(sudo nginx -t 2>&1)

        if echo "\$nginx_check" | grep -q "test is successful"; then
            echo "Nginx configuration for \$domain_without_www is correct."
        else
            echo "Nginx configuration error for \$domain_without_www: \$nginx_check"
            exit 1
        fi

        # Validate and reload
        nginx -t && systemctl reload nginx
        if [ \$? -eq 0 ]; then
            echo "Domains \$DOMAIN sets to default config"
        else
            echo "Error in nginx configuration"
            rm -f "\$LINK" "\$TARGET"
            exit 1
        fi

        exit 1
    fi
fi

SSLCertificateFile="/etc/letsencrypt/live/\$domain_without_www/fullchain.pem"
SSLCertificateKeyFile="/etc/letsencrypt/live/\$domain_without_www/privkey.pem"

if [[ ! -f "\$certPath" && "\$le" -ne 0 && ! -f "/opt/killbot/ssl/\$domain_without_www/fullchain.pem" ]]; then

   echo "Obtaining letsencrypt certificate...."

    if [ -z "\$email" ]; then
        echo "Error: Add -e [email] parametr to receive letsencript cert."
        exit 1
    fi
    
    output=\$(/opt/killbot/apache80_letsencrypt_test.sh "\$domain_without_www" "\$backend_ip")

    if echo "\$output" | grep -q "created"; then
        :
    else
        echo "Error: There is no confirmation of file creation in the script output:"
        echo "\$output"
        exit 1
    fi
    
    apache_check=\$(sudo apachectl configtest 2>&1)

    if echo "\$apache_check" | grep -q "Syntax OK"; then
        :
    else
        echo "Apache configuration error for \$domain: \$apache_check"

        sudo a2dissite "\$domain_without_www-le"
        sudo rm -f "/etc/apache2/sites-available/\$domain_without_www-le.conf"

        exit 1
    fi

    nginx_check=\$(sudo nginx -t 2>&1)

    if echo "\$nginx_check" | grep -q "test is successful"; then
        echo "Nginx configuration for \$domain_without_www is correct."
    else
        echo "Nginx configuration error for \$domain_without_www: \$nginx_check"
        exit 1
    fi
    
    sudo a2ensite "\$domain_without_www-le"
    sudo ln -sf /etc/nginx/sites-available/\$domain_without_www.conf /etc/nginx/sites-enabled/

    sudo a2dissite "\$domain_without_www"
    sudo a2dissite "\$domain_without_www-killbot"    
    sudo systemctl reload apache2
    sudo systemctl nginx reload

    echo "The site \$domain_without_www-le has been successfully enabled and Apache has been restarted."
    
    sudo rm -rf /etc/letsencrypt/live/"\$domain_without_www"\*
    sudo rm -rf /etc/letsencrypt/archive/"\$domain_without_www"\*
    sudo rm -rf /etc/letsencrypt/renewal/"\$domain_without_www"\*.conf

    if [[ "\$le" -eq 2 ]]; then
        echo "Error: le=2 not supported!"
        exit 1;

        output=\$(dig @"\$DNSServer" +short AAAA "\$domain_without_www")
            if echo "\$output" | grep -q .; then
                echo "ERROR: remove AAAA dns record for \$domain_without_www"        
                exit 1;
            fi

        output=\$(sudo certbot certonly --manual --preferred-challenges=dns \
          --cert-name "\$domain_without_www" \
          -d "\$domain_without_www" \
          -d "*.\$domain_without_www" \
          --email "\$email" \
          --agree-tos \          
          --manual-public-ip-logging-ok \
          --expand \
          2>&1)

        # Check result and show DNS instructions if needed
        if [[ \$? -ne 0 ]]; then
            echo "Error obtaining SSL certificate:"
            echo "\$output"

            # Try to extract DNS record information
            if grep -q "Please deploy a DNS TXT record" <<< "\$output"; then
                echo -e "\n\033[1;31mATTENTION: You need to manually add a DNS record:\033[0m"
                # Extract record name and value
                dns_record=\$(grep -oP "acme-challenge\.[^\s]+" <<< "\$output" | head -1)
                dns_value=\$(grep -oP 'TXT record \K[^\s]+' <<< "\$output" | head -1)

                echo -e "Add this TXT record to your DNS zone:"
                echo -e "Name: \033[1;32m_\$dns_record\033[0m"
                echo -e "Value: \033[1;32m\$dns_value\033[0m"
                echo -e "TTL: 300 (or default value)"
                echo -e "\nAfter adding, wait 2-5 minutes for DNS propagation and try again."

                echo -e "\nYou can verify DNS propagation with:"
                echo -e "dig -t TXT _acme-challenge.\$domain_without_www +short"
            fi
            exit 1
        else
            echo -e "\033[1;32mSuccess! Wildcard certificate obtained for:\033[0m"
            echo "- Primary domain: \$domain"
            echo "- All subdomains: *.\$domain_without_www"

            echo -e "\nCertificate details:"
            sudo certbot certificates --cert-name "\$domain_without_www"
        fi

    else
        if echo "\$ip_without_www_list" | grep -Fxq "\$SERVER_IP" && \
            echo "\$ip_with_www_list"    | grep -Fxq "\$SERVER_IP"; then

            output=\$(dig @"\$DNSServer" +short AAAA "\$domain_without_www")
            if echo "\$output" | grep -Eq '^[0-9a-fA-F:]+\$'; then
                echo "ERROR: remove AAAA dns record for \$domain_without_www"
                exit 1
            fi

            output=\$(dig @"\$DNSServer" +short AAAA "\$domain_with_www")
            if echo "\$output" | grep -Eq '^[0-9a-fA-F:]+\$'; then
                echo "ERROR: remove AAAA dns record for \$domain_with_www"
                exit 1
            fi

            output=\$(sudo certbot certonly --webroot --cert-name "\$domain_without_www" -w /var/www/html -d "\$domain_without_www" -d "\$domain_with_www" --email "\$email" --agree-tos --non-interactive 2>&1)
        else

            output=\$(dig @"\$DNSServer" +short AAAA "\$domain_without_www")
            if echo "\$output" | grep -Eq '^[0-9a-fA-F:]+\$'; then
                echo "ERROR: remove AAAA dns record for \$domain_without_www"
                exit 1
            fi

            output=\$(sudo certbot certonly --webroot --cert-name "\$domain_without_www" -w /var/www/html -d "\$domain" --email "\$email" --agree-tos --non-interactive 2>&1)
        fi
    fi

    if echo "\$output" | grep -q -E "Congratulations|Successfully";  then
        
        SSLCertificateFile="/etc/letsencrypt/live/\$domain_without_www/fullchain.pem"
        SSLCertificateKeyFile="/etc/letsencrypt/live/\$domain_without_www/privkey.pem"

        echo "The certificate has been successfully obtained."

        sudo a2dissite "\$domain_without_www-le"
        sudo rm -f "/etc/apache2/sites-available/\$domain_without_www-le.conf"

    else
        echo "Error obtaining the certificate: \$output"
        exit 1
    fi   

fi

if [[ "\$le" -eq 0 ]]; then
    SSLCertificateFile="/etc/apache2/ssl/\$domain_without_www-selfsigned.crt"
    SSLCertificateKeyFile="/etc/apache2/ssl/\$domain_without_www-selfsigned.key"
fi

# Check is sert is on: (enabled != 0)
enabled_file="/opt/killbot/ssl/\$domain_without_www/enabled"
enabled_value="1"
if [[ -f "\$enabled_file" ]]; then
    enabled_value=\$(cat "\$enabled_file" 2>/dev/null || echo "1")
fi
if [[ "\$enabled_value" != "0" ]]; then
    if [[ -f "/opt/killbot/ssl/\$domain_without_www/privkey.pem" ]]; then
      SSLCertificateFile="/opt/killbot/ssl/\$domain_without_www/fullchain.pem"
      SSLCertificateKeyFile="/opt/killbot/ssl/\$domain_without_www/privkey.pem"
      echo "Custom SSL certificate is used!"

        # Delete the Let's Encrypt certificate without a prompt
        certbot delete --cert-name "\$domain_without_www" --non-interactive
    fi
fi


# Create DNS API configuration for wildcard SSL certificates
if [[ "\$use_sub_domains" == "1" && -n "\$api_env_content" ]]; then
    echo "Creating DNS API configuration for wildcard SSL certificates..."
    
    # Create directory for domain certificates
    sudo mkdir -p "/opt/killbot/certs/\$domain_without_www"
    sudo chown -R www-data:www-data "/opt/killbot/certs/\$domain_without_www"
    sudo chmod -R 755 "/opt/killbot/certs/\$domain_without_www"
    
    # Create api.env file with provided content
    api_env_file="/opt/killbot/certs/\$domain_without_www/api.env"
    enabled_file="/opt/killbot/certs/\$domain_without_www/enabled"
    
    # Decode base64 content and write to file
    echo "\$api_env_content" | base64 -d > "\$api_env_file"
    
    # Set proper permissions for api.env file
    sudo chown www-data:www-data "\$api_env_file"
    sudo chmod 600 "\$api_env_file"
    
    # Remove enabled file when api.env is created/updated (new credentials available)
    if [[ -f "\$enabled_file" ]]; then
        rm -f "\$enabled_file"
        log "Removed enabled file for \$domain_without_www - new credentials available"
    fi
    
    # Create provider file with DNS provider name
    if [[ -n "\$dns_provider" ]]; then
        provider_file="/opt/killbot/certs/\$domain_without_www/provider"
        echo "\$dns_provider" > "\$provider_file"
        
        # Set proper permissions for provider file
        sudo chown www-data:www-data "\$provider_file"
        sudo chmod 644 "\$provider_file"
        
        echo "Created provider file: \$provider_file with content: \$dns_provider"
    fi
    
    echo "Running DNS API check for \$api_env_file ..."
    if /opt/killbot/acme_check_api.sh "\$api_env_file"; then
      echo "DNS API check passed, continuing..."
    else
      echo "DNS API check failed for \$api_env_file"
      exit 1
    fi

    echo "DNS API configuration created at: \$api_env_file"
fi


#sudo systemctl reload apache2

lang="ru"
metrika=""
instanceID=""


token_killbot=$KILLBOT_ACCOUNT_TOKEN  # partner API key
tokens_file="/opt/killbot/tokens"
#Read token from file if exist
if [[ -n "\$email" && -z "\$token" ]]; then
    token=\$(grep "^\$email:" "\$tokens_file" | cut -d':' -f2)
fi

kb_domain=""

if curl --connect-timeout 5 -k -m 3 -sL "https://killbot.ru/api/login" | grep -q '^{.*"code":'; then
    kb_domain="killbot.ru"
else
    kb_domain="my.kill-bot.net"
fi

if [[ -z "\$token" ]]; then
    
    kb_url="https://\$kb_domain/api/login?create=1&d=\$domain"

    echo "Creating account on KillBot for email = \$email"
    response=\$(curl --connect-timeout 5 -s -k -H "X-Token: \$token_killbot" -H "X-Email: \$email" "\$kb_url")

    #echo "response = \$response"

    code=\$(echo "\$response" | jq -r '.code')
    message=\$(echo "\$response" | jq -r '.message')

    #error check
    if [[ "\$code" -ne 200 ]]; then
        echo "Error: Account for \$email already exist. To continue take your API key: https://killbot.ru/api-key ( or https://killbot.ru/api-key ) and run command with your API token like this: "
        echo "kb install -d \$domain -t YOUR_API_TOKEN -ip \$backend_ip"
        echo "Original error message: \$message"
        exit 1
    fi
    
    token=\$(echo "\$response" | jq -r '.data')
    echo "\$email:\$token" >> "\$tokens_file"
    echo "Token saved to file: \$tokens_file"
fi

echo "Creating the KillBot script"
kb_url="https://\$kb_domain/api/create_script?integration_type=2&instance_id=\$instanceID&ip=\$backend_ip&url=https://\$domain"
response=\$(curl --connect-timeout 5 -s -k -H "X-Email: \$email" -H "X-Token: \$token_killbot" -H "X-Tokenauth: \$token" "\$kb_url")
#echo "\$response"

# Check if JSON is correct
code=\$(echo "\$response" | jq -r '.code' 2>/dev/null)
message=\$(echo "\$response" | jq -r '.message' 2>/dev/null)

# IF parse error
if [ \$? -ne 0 ] || ! [[ "\$code" =~ ^[0-9]+\$ ]]; then
    echo "Error: Failed to parse JSON response"
    echo "URL: \$kb_url"
    echo "Response: \$response"
    exit 1
fi

code=\$(echo "\$response" | jq -r '.code')
message=\$(echo "\$response" | jq -r '.message')

if [ "\$code" != "200" ]; then
    echo "Error: \$message"
    exit 1
fi

json_data=\$(echo "\$response" | jq -r '.data' | jq -r '.')
cv_json=\$(echo "\$json_data" | jq -r '.cv' | jq -r '.')
metrika=\$(echo "\$json_data" | jq -r '.metrika' | jq -r '.')

php_script=\$(echo "\$cv_json" | jq -r '.php')
php_script_escaped=\$(echo "\$php_script" | sed 's/\\\$/\\\\&/g')
apache_script=\$(echo "\$cv_json" | jq -r '.apache')
lua_script=\$(echo "\$cv_json" | jq -r '.lua')
lua_script2=\$(echo "\$cv_json" | jq -r '.lua2')

#echo "PHP Script: \$php_script"
#echo "Apache Config: \$apache_script"
#echo "LUA Config: \$lua_script"


#Updating kb.lus
#sed "s|kb_lua_script|\$lua_script|g" /opt/killbot/kb.lua > /opt/killbot/lua/\$domain_without_www.lua


make_lua_array() {
    local varname="\$1"
    local values="\$2"
    local result="local \$varname = {"
    IFS=',' read -ra arr <<< "\$values"
    for val in "\${arr[@]}"; do
        val="\${val//\\"/\\\\\"}"  
        result+="    \"\$val\","
    done
    result+="}"
    echo -e "\$result"
}

is_wildcard_cert() {
  local certfile="\$1"  
  if [[ ! -f "\$certfile" ]]; then return 1; fi

  #get domain from certpath like "SERTDIR/{domain}/fullchain.pem"
  local domain=\$(echo "\$certfile" | rev | cut -d'/' -f2 | rev)

  mapfile -t dns_entries < <(openssl x509 -in "\$certfile" -noout -text 2>/dev/null | grep -oP 'DNS:[^,]+' | sed 's/^DNS://')
  for n in "\${dns_entries[@]}"; do
    if [[ "\$n" == "*.\$domain" ]]; then
      return 0
    fi
  done
  return 1
}

wlpath="\$wlpath,/.well-known/"

lua_agents=\$(make_lua_array "allowed_agents" "\$wlua")
lua_paths=\$(make_lua_array "allowed_paths" "\$wlpath")
lua_ips=\$(make_lua_array "allowed_ips" "\$wlip")

subdomain_alias=""
if is_wildcard_cert "\$SSLCertificateFile"; then
    subdomain_alias="ServerAlias *.\$domain_without_www"
    echo "Wildcard certificate detected: \$SSLCertificateFile. Configuring Apache for all subdomains"

    log_file="/var/log/killbot/setup_killbot_reverse_proxy_\$(echo "\$domain_without_www" | sed 's/[^a-zA-Z0-9._-]/_/g').log"
    nohup /opt/killbot/setup_killbot_reverse_proxy.sh "\$domain_without_www" -y >> "\$log_file" 2>&1 </dev/null &
    echo "OK: setup_killbot_reverse_proxy started in background (log: \$log_file)"
else
    echo "Wildcard certificate not detected. Removing killbot_revers files for \$domain_without_www"
    rm -f \
        "/opt/killbot/settings/\$domain_without_www/killbot_revers" \
        "/opt/killbot/settings/\$domain_without_www/killbot_revers_checked"
fi


if [[ "\$le" -eq 0 ]]; then    
    subdomain_alias="ServerAlias *.\$domain_without_www"
    echo "For self signed serts configure Apache for all subdomains"
fi

#Updating kb.lua
sed -e "s|kb_domain|\$domain_without_www|g" -e "s|kb_lua_script|\$lua_script|g" -e "s|kb2_lua_script|\$lua_script2|g" -e "s|kb_lua_agents|\$lua_agents|g" -e "s|kb_lua_paths|\$lua_paths|g" -e "s|kb_lua_ips|\$lua_ips|g" /opt/killbot/kb.lua > /opt/killbot/lua/\$domain_without_www.lua



#sudo chown -R www-data:www-data /opt/killbot/php/\$domain_without_www.php
#chmod 755 /opt/killbot/php/\$domain_without_www.php

#Updating apache443-killbot.sh
sed -e "s|\*\*\*SubdomainAlias\*\*\*|\$subdomain_alias|g" -e "s|\*\*\*server_ip\*\*\*|\$SERVER_IP|g" -e "s|\*\*\*apache_script\*\*\*|\$apache_script|g"  -e "s|\*\*\*SSLCertificateFile\*\*\*|\$SSLCertificateFile|g" -e "s|\*\*\*SSLCertificateKeyFile\*\*\*|\$SSLCertificateKeyFile|g"  /opt/killbot/apache443-killbot.sh > /opt/killbot/sh/\$domain_without_www-killbot.sh
sed -e "s|\*\*\*SubdomainAlias\*\*\*|\$subdomain_alias|g" -e "s|\*\*\*server_ip\*\*\*|\$SERVER_IP|g" -e "s|\*\*\*SSLCertificateFile\*\*\*|\$SSLCertificateFile|g" -e "s|\*\*\*SSLCertificateKeyFile\*\*\*|\$SSLCertificateKeyFile|g"  /opt/killbot/apache443.sh > /opt/killbot/sh/\$domain_without_www.sh

#Disable SSL if the domain does not have "www"
if [[ "\$ip_without_www_list" == "\$ip_with_www_list" && -n "\$ip_without_www_list" ]]; then
    sed -i "s|\*\*\*www_ssl_on\*\*\*|SSLEngine on|g" /opt/killbot/sh/\$domain_without_www-killbot.sh    
else
    sed -i "s|\*\*\*www_ssl_on\*\*\*||g" /opt/killbot/sh/\$domain_without_www-killbot.sh    
fi

sudo chmod +x /opt/killbot/sh/\$domain_without_www-killbot.sh /opt/killbot/sh/\$domain_without_www.sh

#Determine the primary mirror based on the www variable
if [ "\$www" -eq 0 ]; then
    main_domain="\$domain_without_www"
    secondary_domain="www.\$domain_without_www"
else
    main_domain="www.\$domain_without_www"
    secondary_domain="\$domain_without_www"
fi

# Creating an Apache configuration file with KillBot support so that the site opens through the KillBot verification screen.
output=\$(/opt/killbot/sh/\$domain_without_www-killbot.sh "\$domain_without_www" "\$main_domain" "\$secondary_domain" "\$backend_ip" "\$wlua" "\$wlpath" "\$wlip" "\$cdn_static" "\$cdn_domain" "\$cdn_paths" "\$https")

if echo "\$output" | grep -q "created"; then
    echo "The Apache file with the KillBot screen on port 443 has been created."
else
    echo "Error: There is no confirmation of file creation in the script output."
    echo "Script output: \$output"
    exit 1
fi

# Creating an Apache configuration file without KillBot support - simple proxying.
#output=\$(/opt/killbot/apache443.sh "\$domain_without_www" "\$backend_ip" "\$folder")
output=\$(/opt/killbot/sh/\$domain_without_www.sh "\$domain_without_www" "\$main_domain" "\$secondary_domain" "\$backend_ip" "\$https")


if echo "\$output" | grep -q "created"; then
    echo "The Apache file without KillBot on port 443 has been created."
else
    echo "Error: There is no confirmation of file creation in the script output."
    echo "Script output: \$output"
    exit 1
fi

# Disable SSL if the domain does not have www
if [[ "\$ip_without_www_list" == "\$ip_with_www_list" && -n "\$ip_without_www_list" ]]; then
    sed -i "s|\*\*\*www_ssl_on\*\*\*|SSLEngine on|g" /etc/apache2/sites-available/\$domain_without_www.conf    
else
    sed -i "s|\*\*\*www_ssl_on\*\*\*||g" /etc/apache2/sites-available/\$domain_without_www.conf
fi

if [ "\$backend_ip" != "localhost" ]; then
    echo "The Apache server for the site \$domain_without_www is configured as a reverse proxy to IP=\$backend_ip"
    sed -i "s|#Define PROXY_ENABLE|Define PROXY_ENABLE|g" /etc/apache2/sites-available/\$domain_without_www-killbot.conf
    sed -i "s|#Define PROXY_ENABLE|Define PROXY_ENABLE|g" /etc/apache2/sites-available/\$domain_without_www.conf
else
    echo "The Apache server for the site \$domain_without_www is configured to the localhost directory \$folder"
fi

apache_check=\$(sudo apachectl configtest 2>&1)

if echo "\$apache_check" | grep -q "Syntax OK"; then
    echo "Apache configuration is correct."
else
    echo "Apache configuration error: \$apache_check"

    #sudo a2dissite "\$domain_without_www"
    #sudo rm -f "/etc/apache2/sites-available/\$domain_without_www.conf"

    exit 1
fi

sudo rm -f /etc/apache2/sites-enabled/\$domain_without_www-killbot.conf
sudo rm -f /etc/apache2/sites-enabled/\$domain_without_www.conf
sudo rm -f /etc/nginx/sites-enabled/\$domain_without_www.conf

sudo a2dissite "\$domain_without_www"
sudo a2ensite "\$domain_without_www-killbot"
sudo ln -sf /etc/nginx/sites-available/\$domain_without_www.conf /etc/nginx/sites-enabled/

apache_check=\$(sudo apachectl configtest 2>&1)

if echo "\$apache_check" | grep -q "Syntax OK"; then
    echo "Apache configuration is correct."
else
    echo "Apache configuration error: \$apache_check"

    #sudo a2dissite "\$domain_without_www"
    #sudo rm -f "/etc/apache2/sites-available/\$domain_without_www.conf"

    exit 1
fi

nginx_check=\$(sudo nginx -t 2>&1)

if echo "\$nginx_check" | grep -q "test is successful"; then
    echo "Nginx configuration is correct."
else
    echo "Nginx configuration error: \$nginx_check"
    exit 1
fi

NEW_APACHE_HASH=\$(get_apache_hash)
NEW_NGINX_HASH=\$(get_nginx_hash)

if [ "\$CURRENT_APACHE_HASH" != "\$NEW_APACHE_HASH" ]; then
    echo "Reloading apache..."
    if systemctl is-active --quiet apache2; then
        kb_systemctl_retry reload apache2 || exit 1
    else
        kb_systemctl_retry start apache2 || exit 1
    fi
    echo "\$(date '+%F %T') install.sh reloaded apache: \$CURRENT_APACHE_HASH != \$NEW_APACHE_HASH" >> /var/log/killbot/install_debug.log || true
fi

if [ "\$CURRENT_NGINX_HASH" != "\$NEW_NGINX_HASH" ]; then
    echo "Reloading nginx..."
    if systemctl is-active --quiet nginx; then
        kb_systemctl_retry reload nginx || exit 1
    else
        kb_systemctl_retry start nginx || exit 1
    fi
    echo "\$(date '+%F %T') install.sh reloaded nginx: \$CURRENT_NGINX_HASH != \$NEW_NGINX_HASH" >> /var/log/killbot/install_debug.log || true
fi

if [ "\$backend_ip" != "localhost" ]; then
    POSTROUTING_FILE="/opt/killbot/postrouting.txt"
    touch "\$POSTROUTING_FILE" 2>/dev/null || true
    if ! grep -Fxq "\$backend_ip" "\$POSTROUTING_FILE" 2>/dev/null; then
        echo "\$backend_ip" >> "\$POSTROUTING_FILE" || true
        postrouting_log_file="/var/log/killbot/update_postrouting.log"
        nohup /opt/killbot/update-postrouting.sh >> "\$postrouting_log_file" 2>&1 </dev/null &
        echo "OK: update-postrouting started in background (log: \$postrouting_log_file)"
    fi
fi


if [ "\$backend_ip" != "localhost" ]; then
    echo "Success: Killbot configuration with verification page for domain \$domain_without_www is configured as a reverse proxy to IP=\$backend_ip"
else
    echo "Success: Killbot configuration with verification page for domain \$domain_without_www  is configured to the localhost directory \$folder"
fi

EOF

sudo chmod +x /opt/killbot/install.sh


# Allow configure KillBot via php
RULE="www-data ALL=(ALL) NOPASSWD: /etc/init.d/kb"
SUDOERS_FILE="/etc/sudoers"
if sudo grep -Fxq "$RULE" "$SUDOERS_FILE"; then
    :
else    
    echo "$RULE" | sudo tee -a "$SUDOERS_FILE" > /dev/null    
fi
RULE="www-data ALL=(ALL) NOPASSWD: /usr/bin/nice, /opt/killbot/install.sh"
SUDOERS_FILE="/etc/sudoers"
if sudo grep -Fxq "$RULE" "$SUDOERS_FILE"; then
    :
else    
    echo "$RULE" | sudo tee -a "$SUDOERS_FILE" > /dev/null    
fi
RULE="www-data ALL=(ALL) NOPASSWD: /opt/killbot/check_host_curl.sh"
SUDOERS_FILE="/etc/sudoers"
if sudo grep -Fxq "$RULE" "$SUDOERS_FILE"; then
    :
else    
    echo "$RULE" | sudo tee -a "$SUDOERS_FILE" > /dev/null    
fi



sudo sudo tee /opt/killbot/update.sh > /dev/null <<EOF
#!/bin/bash
kb_download() {
  local dest="\$1"
  local path="\$2"
  timeout 15 curl --connect-timeout 10 -f -L -o "\$dest" "https://raw.githubusercontent.com/grigoriy-melnikov/KillBot/main/\$path"
}

FILE="/opt/killbot/html/verification.php"
  
    kb_download "\$FILE" "html/verification.html"
    
    if [ \$? -eq 0 ]; then
        echo "The verification page (verification.html) has been successfully loaded."
    else
        echo "Error loading the verification page."
        exit 1
    fi

    #sudo test -f /var/www/html/.htaccess || sudo tee /var/www/html/.htaccess > /dev/null <<EOF
    #<FilesMatch "\.(html|htm)$">
    #    Header set Cache-Control "no-cache, no-store, must-revalidate"
    #    Header set Pragma "no-cache"
    #    Header set Expires 0
    #</FilesMatch>


FILE="/opt/killbot/html/FakeBot.php"

    kb_download "\$FILE" "html/FakeBot.html"

    if [ \$? -eq 0 ]; then
        echo "The FakeBot page (FakeBot.php) has been successfully loaded."
    else
        echo "Error loading the FakeBot page."
        exit 1
    fi

FILE="/opt/killbot/html/Expired.html"

    kb_download "\$FILE" "html/Expired.html"

    if [ \$? -eq 0 ]; then
        echo "The Expired page (Expired.html) has been successfully loaded."
    else
        echo "Error loading the Expired page."
        exit 1
    fi

sudo chown www-data:www-data /opt/killbot/html/FakeBot.php /opt/killbot/html/verification.php

FILE="/opt/killbot/cert_wildcard_new.sh"

    kb_download "\$FILE" "sh/cert_wildcard_new.sh"

    if [ \$? -eq 0 ]; then
        echo "The cert_wildcard_new.sh has been successfully loaded."
    else
        echo "Error loading the cert_wildcard_new.sh."
        exit 1
    fi

FILE="/opt/killbot/off_killbot_protection.sh"

    kb_download "\$FILE" "sh/off_killbot_protection.sh"

    if [ \$? -eq 0 ]; then
        echo "The off_killbot_protection.sh has been successfully loaded."
    else
        echo "Error loading the off_killbot_protection.sh."
        exit 1
    fi

FILE="/opt/killbot/on_killbot_protection.sh"

    kb_download "\$FILE" "sh/on_killbot_protection.sh"

    if [ \$? -eq 0 ]; then
        echo "The on_killbot_protection.sh has been successfully loaded."
    else
        echo "Error loading the on_killbot_protection.sh."
        exit 1
    fi

FILE="/opt/killbot/clean_up_unused_certs.sh"

    kb_download "\$FILE" "sh/clean_up_unused_certs.sh"

    if [ \$? -eq 0 ]; then
        echo "The clean_up_unused_certs.sh has been successfully loaded."
    else
        echo "Error loading the clean_up_unused_certs.sh"
        exit 1
    fi

FILE="/opt/killbot/UpdateAll.sh"

    kb_download "\$FILE" "sh/UpdateAll_nginx.sh"

    if [ \$? -eq 0 ]; then
        echo "The UpdateAll.sh has been successfully loaded."
    else
        echo "Error loading the UpdateAll.sh"
        exit 1
    fi

FILE="/opt/killbot/renew_wildcard.sh"
    kb_download "\$FILE" "sh/renew_wildcard.sh"
    
    if [ \$? -eq 0 ]; then
        echo "The renew_wildcard.sh file has been successfully loaded."
    else
        echo "Error loading the renew_wildcard.sh file."
        exit 1
    fi

FILE="/opt/killbot/acme_check_api.sh"
    kb_download "\$FILE" "sh/acme_check_api.sh"
    
    if [ \$? -eq 0 ]; then
        echo "The acme_check_api.sh file has been successfully loaded."
    else
        echo "Error loading the acme_check_api.sh file."
        exit 1
    fi

FILE="/opt/killbot/official_allowed_ips.sh"
    kb_download "\$FILE" "sh/official_allowed_ips.sh"
    
    if [ \$? -eq 0 ]; then
        echo "The official_allowed_ips.sh file has been successfully loaded."
    else
        echo "Error loading the official_allowed_ips.sh file."
        exit 1
    fi

FILE="/opt/killbot/cert_delete.sh"
    kb_download "\$FILE" "sh/cert_delete.sh"
    
    if [ \$? -eq 0 ]; then  cd /
        echo "The cert_delete.sh file has been successfully loaded."
    else
        echo "Error loading the cert_delete.sh file."
        exit 1
    fi

FILE="/opt/killbot/html/access_denied.html"
    kb_download "\$FILE" "html/access_denied.html"
    
    if [ \$? -eq 0 ]; then
        echo "The access_denied.html file has been successfully loaded."
    else
        echo "Error loading the access_denied.html file."
        exit 1
    fi

FILE="/opt/killbot/html/too_many_requests.html"
    kb_download "\$FILE" "html/too_many_requests.html"
    
    if [ \$? -eq 0 ]; then
        echo "The too_many_requests.html file has been successfully loaded."
    else
        echo "Error loading the too_many_requests.html file."
        exit 1
    fi

FILE="/opt/killbot/f2b/subnet-monitor.sh"
    kb_download "\$FILE" "sh/subnet-monitor.sh"
    
    if [ \$? -eq 0 ]; then
        echo "The subnet-monitor.sh file has been successfully loaded."
    else
        echo "Error loading the subnet-monitor.sh file."
        exit 1
    fi

FILE="/opt/killbot/f2b/unblock_traffic.sh"
    kb_download "\$FILE" "sh/unblock_traffic.sh"
    
    if [ \$? -eq 0 ]; then
        echo "The unblock_traffic.sh file has been successfully loaded."
    else
        echo "Error loading the unblock_traffic.sh file."
        exit 1
    fi
   

FILE="/opt/killbot/f2b/check_apache_and_block.sh"
    kb_download "\$FILE" "sh/check_apache_and_block.sh"
    
    if [ \$? -eq 0 ]; then
        echo "The /opt/killbot/f2b/check_apache_and_block.sh file has been successfully loaded."
    else
        echo "Error loading the /opt/killbot/f2b/check_apache_and_block.sh file."
        exit 1
    fi


FILE="/opt/killbot/f2b/block_all_countries_except.sh"
    kb_download "\$FILE" "sh/block_all_countries_except.sh"
    
    if [ \$? -eq 0 ]; then
        echo "The block_all_countries_except.sh file has been successfully loaded."
    else
        echo "Error loading the block_all_countries_except.sh file."
        exit 1
    fi

FILE="/var/www/html/le_receive_cert.php"
    kb_download "\$FILE" "html/le_custom_server/le_receive_cert.html"

    if [ \$? -eq 0 ]; then
        echo "le_receive_cert.php loaded."
    else
        echo "Error loading le_receive_cert.html"
        exit 1
    fi

sudo chown www-data:www-data /var/www/html/le_receive_cert.php
sudo chmod 644 /var/www/html/le_receive_cert.php

FILE="/opt/killbot/check_killbot_reverse_proxy.sh"
    kb_download "\$FILE" "sh/check_killbot_reverse_proxy.sh"
    
    if [ \$? -eq 0 ]; then
        echo "The check_killbot_reverse_proxy.sh file has been successfully loaded."
    else
        echo "Error loading the check_killbot_reverse_proxy.sh file."
        exit 1
    fi

FILE="/opt/killbot/setup_killbot_reverse_proxy.sh"
    kb_download "\$FILE" "sh/setup_killbot_reverse_proxy.sh"
    
    if [ \$? -eq 0 ]; then
        echo "The setup_killbot_reverse_proxy.sh file has been successfully loaded."
    else
        echo "Error loading the setup_killbot_reverse_proxy.sh file."
        exit 1
    fi

FILE="/opt/killbot/update-postrouting.sh"
    kb_download "\$FILE" "sh/update-postrouting.sh"
    
    if [ \$? -eq 0 ]; then
        echo "The update-postrouting.sh file has been successfully loaded."
    else
        echo "Error loading the update-postrouting.sh file."
        exit 1
    fi

FILE="/opt/killbot/update-symmetric-ip.sh"
    kb_download "\$FILE" "sh/update-symmetric-ip.sh"
    
    if [ \$? -eq 0 ]; then
        echo "The update-symmetric-ip.sh file has been successfully loaded."
    else
        echo "Error loading the update-symmetric-ip.sh file."
        exit 1
    fi

FILE="/opt/killbot/check_host_curl.sh"
    kb_download "\$FILE" "sh/check_host_curl.sh"
    
    if [ \$? -eq 0 ]; then
        echo "The check_host_curl.sh file has been successfully loaded."
    else
        echo "Error loading the check_host_curl.sh file."
        exit 1
    fi

sudo chmod +x /opt/killbot/check_killbot_reverse_proxy.sh /opt/killbot/setup_killbot_reverse_proxy.sh /opt/killbot/update-postrouting.sh /opt/killbot/update-symmetric-ip.sh /opt/killbot/check_host_curl.sh
sudo chmod +x /opt/killbot/f2b/subnet-monitor.sh  /opt/killbot/renew_wildcard.sh /opt/killbot/cert_delete.sh /opt/killbot/acme_check_api.sh /opt/killbot/on_killbot_protection.sh /opt/killbot/off_killbot_protection.sh /opt/killbot/official_allowed_ips.sh /opt/killbot/cert_wildcard_new.sh /opt/killbot/clean_up_unused_certs.sh /opt/killbot/UpdateAll.sh
sudo chmod +x  /opt/killbot/f2b/block_all_countries_except.sh  /opt/killbot/f2b/check_apache_and_block.sh  /opt/killbot/f2b/unblock_traffic.sh /opt/killbot/official_allowed_ips.sh

EOF

sudo chmod +x /opt/killbot/update.sh

SERVER_IP=$(curl -s http://checkip.amazonaws.com)
#echo "Public server IP: $SERVER_IP"

# Adding blocking rules to prevent the site from being accessed by IP address
#BLOCK_RULES_80="\n<VirtualHost 127.0.0.1:8080>\n    ServerName $SERVER_IP\n    <Location '/kb.php'>\n        Require all granted\n    </Location>\n    <Location '/'>\n        Require all denied\n        ErrorDocument 403 'Forbidden'\n    </Location>\n</VirtualHost>\n"
#BLOCK_RULES_443="\n<VirtualHost 127.0.0.1:8443>\n    ServerName $SERVER_IP\n    <Location '/kb.php'>\n        Require all granted\n    </Location>\n    <Location '/'>\n        Require all denied\n        ErrorDocument 403 'Forbidden'\n    </Location>\n</VirtualHost>\n"

BLOCK_RULES_443="\n<VirtualHost 127.0.0.1:8443>\n    ServerName $SERVER_IP\n    DocumentRoot /var/www/html\n\n    <Directory \"/var/www/html\">\n        Require all denied\n        <Files \"kb.php\">\n            Require all granted\n        </Files>\n        <Files \"le_receive_cert.php\">\n            Require all granted\n        </Files>\n    </Directory>\n\n</VirtualHost>\n"
BLOCK_RULES_80="\n<VirtualHost 127.0.0.1:8080>\n    ServerName $SERVER_IP\n    DocumentRoot /var/www/html\n\n      RewriteEngine On\n\n    RewriteCond %{REQUEST_METHOD} ^OPTIONS\n\n    RewriteRule .* - [R=403,L]\n\n  <Directory \"/var/www/html\">\n        Require all denied\n        <Files \"kb.php\">\n            Require all granted\n        </Files>\n        <Files \"le_receive_cert.php\">\n            Require all granted\n        </Files>\n    </Directory>\n\n</VirtualHost>\n"

FILE="/etc/apache2/sites-available/000-default.conf"
if [ -f "$FILE" ]; then
    if ! grep -q "ServerName $SERVER_IP" "$FILE"; then
        echo -e "$BLOCK_RULES_80" | sudo tee -a "$FILE" > /dev/null
        echo "Rules added to $FILE"
    else
        echo "Rules already exist in $FILE"
    fi
else
    echo "File $FILE not found, skipping..."
fi

# Stopping Apache before making changes
sudo systemctl stop apache2

# Changing the number of concurrent connections. Modifying KeepAliveTimeout configuration and
CONFIG_FILE="/etc/apache2/apache2.conf"
MPM_PREFORK_FILE="/etc/apache2/mods-available/mpm_prefork.conf"
MPM_EVENT_FILE="/etc/apache2/mods-available/mpm_event.conf"
MPM_WORKER_FILE="/etc/apache2/mods-available/mpm_worker.conf"

if ! grep -qE '^[[:space:]]*ListenBacklog[[:space:]]' "$CONFIG_FILE"; then
    echo "ListenBacklog 4096" | sudo tee -a "$CONFIG_FILE" > /dev/null
    echo "ListenBacklog 4096 added to $CONFIG_FILE"
fi

# Set KeepAliveTimeout to 1 second
sudo sed -i 's/^KeepAliveTimeout.*/KeepAliveTimeout 1/' "$CONFIG_FILE"

# Set maximum number of concurrent connections in Apache
sudo sed -i "s/^MaxRequestWorkers.*/MaxRequestWorkers $MAX_CONNECTIONS_WORKERS/" "$CONFIG_FILE"

# Configure MPM settings (prefork, event, worker)
for MPM_FILE in "$MPM_PREFORK_FILE" "$MPM_EVENT_FILE" "$MPM_WORKER_FILE"; do
    if [ -f "$MPM_FILE" ]; then
        sudo cp "$MPM_FILE" "$MPM_FILE.bak"
        sudo sed -i "s/^\s*MaxRequestWorkers.*/    MaxRequestWorkers $MAX_CONNECTIONS_WORKERS/" "$MPM_FILE"
        sudo sed -i "s/^\s*MaxConnectionsPerChild.*/    MaxConnectionsPerChild 1000/" "$MPM_FILE"

        # Check whether ServerLimit is present
        if grep -q "^\s*ServerLimit" "$MPM_FILE"; then
            # If present, update it
            sudo sed -i "s/^\s*ServerLimit.*/    ServerLimit $MAX_CONNECTIONS/" "$MPM_FILE"
        else
            # If missing, add it right after MaxRequestWorkers
            sudo sed -i "/^\s*MaxRequestWorkers.*/a\    ServerLimit $MAX_CONNECTIONS" "$MPM_FILE"
        fi

    fi
done


# Set SSLSessionCache to 2MB if not already set
SSL_CONF="/etc/apache2/mods-available/ssl.conf"
echo "Checking and updating SSLSessionCache..."

if [ -f "$SSL_CONF" ]; then
    if grep -q "^SSLSessionCache.*2097152" "$SSL_CONF"; then
        echo "SSLSessionCache is already set to 2097152 — no changes made."
    elif grep -q "^SSLSessionCache" "$SSL_CONF"; then
        # Replace the existing SSLSessionCache line with the desired value
        sudo sed -i 's|^SSLSessionCache.*|SSLSessionCache shmcb:/var/cache/apache2/ssl_scache(33554432)|' "$SSL_CONF"
        echo "SSLSessionCache updated to 2097152."
    else
        # If SSLSessionCache is not defined, append the correct value
        echo "SSLSessionCache shmcb:/var/cache/apache2/ssl_scache(2097152)" | sudo tee -a "$SSL_CONF" > /dev/null
        echo "SSLSessionCache set to 2097152."
    fi
else
    echo "File $SSL_CONF not found! Exiting."
    exit 1
fi


SYSCTL_CONF="/etc/sysctl.conf"

# Lines to be added
CONFIG_LINES=(
"net.ipv6.conf.all.disable_ipv6 = 1"
"net.ipv6.conf.default.disable_ipv6 = 1"
"net.ipv6.conf.lo.disable_ipv6 = 1"
)

echo "Checking and adding IPv6 disable settings to $SYSCTL_CONF..."

for line in "${CONFIG_LINES[@]}"; do
    # Escape dots for grep
    escaped_line=$(echo "$line" | sed 's/\./\\./g')
    if grep -q "^$escaped_line" "$SYSCTL_CONF"; then
        echo "Already present: $line"
    else
        echo "$line" | sudo tee -a "$SYSCTL_CONF" > /dev/null
        echo "Added: $line"
    fi
done

# Apply changes immediately
echo "Applying sysctl settings..."
sudo sysctl -p

echo "IPv6 disable settings are applied and persisted."


CONF_FILE="/etc/apache2/apache2.conf"
MUTEX_LINE="#Mutex posixsem rewrite-map"

#disable mutex
if grep -Fxq "$MUTEX_LINE" "$CONF_FILE"; then
    echo "mutex already exist in $CONF_FILE"
else
    echo "$MUTEX_LINE" | sudo tee -a "$CONF_FILE" > /dev/null
    echo "mutex added to $CONF_FILE"
fi

# Path to configuration file
MODSEC_DIR="/etc/modsecurity"
MODSEC_FILE="${MODSEC_DIR}/killbot-bots.conf"

# Create /etc/modsecurity directory if it doesn't exist
sudo mkdir -p "$MODSEC_DIR"

# Create configuration file to prevent large number of bot visits /etc/modsecurity/killbot.conf
sudo tee "$MODSEC_FILE" > /dev/null <<EOL
# Enable request processing
SecRuleEngine On

SecAction "id:1001,phase:1,pass,nolog,setvar:tx.kbRes_counter=0"

SecRule REQUEST_COOKIES "kbRes=true" \
    "id:1002,phase:2,pass,nolog,setvar:tx.kbRes_counter=+1"

# Check if counter exceeds limit
SecRule TX:kbRes_counter "@gt $MAX_CONNECTIONS_BOTS" \
    "id:1003,phase:2,deny,status:302,redirect:/BlockBot.html,msg:'Bot connection limit exceeded'"
EOL


MODSEC_FILE="${MODSEC_DIR}/killbot-slow.conf"
# Create configuration file to prevent slow connections /etc/modsecurity/killbot-slow.conf
sudo tee "$MODSEC_FILE" > /dev/null <<EOL
# Enable request processing
SecRuleEngine On

# Record the request processing start time
SecRule REQUEST_URI "@streq /opt/killbot/verification.php" \
    "id:2001,phase:1,pass,nolog,setvar:tx.start_time=%{TIME}"

# Check if processing time exceeds 5 seconds
SecRule TX:START_TIME "@lt %{TIME}-5" \
    "id:2002,phase:4,deny,status:408,msg:'Slow request detected',log,chain"
SecRule REQUEST_URI "@streq /opt/killbot/verification.php"
EOL

MODSEC_FILE="${MODSEC_DIR}/killbot-ip.conf"
# Create configuration file for multiple requests to verification.php /etc/modsecurity/killbot-ip.conf
sudo tee "$MODSEC_FILE" > /dev/null <<EOL
# Enable request processing
SecRuleEngine On

# Initialize counter only for /opt/killbot/verification.php
SecRule REQUEST_URI "@streq /opt/killbot/verification.php" \
    "id:3001,phase:1,pass,nolog,initcol:ip=%{REMOTE_ADDR}"

# Increment request counter for current IP
SecRule REQUEST_URI "@streq /opt/killbot/verification.php" \
    "id:3002,phase:2,pass,nolog,setvar:ip.requests=+1"

# Check if request count exceeds limit (MAX_CONNECTIONS_IP_VP)
SecRule IP:REQUESTS "@gt $MAX_CONNECTIONS_IP_VP" \
    "id:3003,phase:2,deny,status:429,msg:'Too many requests from this IP',log"
EOL


CONFIG_FILE="/etc/apache2/mods-available/security2.conf"
# Check if the line is already commented
if grep -q '^\s*#\s*IncludeOptional /usr/share/modsecurity-crs/\*\.load' "$CONFIG_FILE"; then
  echo "Line is already commented. Doing nothing."
fi
# If line is not commented, comment it out
sed -i '/^\s*IncludeOptional \/usr\/share\/modsecurity-crs\/\*\.load/s/^/# /' "$CONFIG_FILE"

# Path to Apache2 configuration file in systemd
CONFIG_FILE="/etc/systemd/system/apache2.service.d/autorestart.conf"

# Create configuration directory if it doesn't exist
mkdir -p /etc/systemd/system/apache2.service.d

# Create or modify configuration file
echo "[Service]" > "$CONFIG_FILE"
echo "Restart=always" >> "$CONFIG_FILE"
echo "RestartSec=10" >> "$CONFIG_FILE"

echo "🔧 Enabling nginx auto-restart via systemd..."
# Create the systemd override directory
mkdir -p /etc/systemd/system/nginx.service.d
# Write the config
cat > /etc/systemd/system/nginx.service.d/override.conf <<'EOF'
[Service]
# Increase the file descriptor limit
LimitNOFILE=200000
# Restart automatically on crash
Restart=always
RestartSec=10
[Unit]
StartLimitIntervalSec=60
StartLimitBurst=10
EOF




echo "🔄 Reloading systemd..."
systemctl daemon-reexec
systemctl daemon-reload

# Define variables for easy configuration
APACHE_USER="www-data"
SERVICE_NAME="apache2"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# 1. Configure system-wide file descriptor limit
echo "Configuring system-wide file descriptors..."
# Remove existing entry if present and append new value
sed -i "/fs.file-max/d" /etc/sysctl.conf
echo "fs.file-max = $MAX_OPEN_FILES_SYS" >> /etc/sysctl.conf
sysctl -p

# 2. Configure user limits in limits.conf
echo "Configuring user limits..."
# Function to update or add limit
update_limit() {
    local user=$1
    local type=$2
    local limit=$3
    local value=$4

    # Escape special characters in user pattern
    local user_pattern=$(sed 's/[][\.*^$]/\\&/g' <<< "$user")

    # Update existing entry or append new one
    sed -i "/^$user_pattern[[:space:]]\+$type[[:space:]]\+$limit/d" /etc/security/limits.conf
    echo "$user        $type    $limit      $value" >> /etc/security/limits.conf
}

# Update limits for different users
update_limit "$APACHE_USER" "soft" "nofile" "$MAX_OPEN_FILES"
update_limit "$APACHE_USER" "hard" "nofile" "$MAX_OPEN_FILES"
update_limit "*" "soft" "nofile" "$MAX_OPEN_FILES"
update_limit "*" "hard" "nofile" "$MAX_OPEN_FILES"
update_limit "root" "soft" "nofile" "$MAX_OPEN_FILES"
update_limit "root" "hard" "nofile" "$MAX_OPEN_FILES"

# 3. Configure systemd global limits
echo "Configuring systemd global limits..."
sed -i "/^DefaultLimitNOFILE=/d" /etc/systemd/system.conf
echo "DefaultLimitNOFILE=$MAX_OPEN_FILES" >> /etc/systemd/system.conf

# 4. Configure Apache service limits
echo "Configuring Apache service limits..."
mkdir -p /etc/systemd/system/${SERVICE_NAME}.service.d/
cat << EOF > /etc/systemd/system/${SERVICE_NAME}.service.d/limit_nofile.conf
[Service]
Nice=0
LimitNOFILE=$MAX_OPEN_FILES
LimitNPROC=$MAX_PROCESSES
EOF

# 5. Configure PAM modules
echo "Configuring PAM..."
# Remove existing entry if present and append new value
sed -i "/pam_limits\.so/d" /etc/pam.d/common-session
echo "session required pam_limits.so" >> /etc/pam.d/common-session

PAM_LINE="session required pam_limits.so"
PAM_FILE="/etc/pam.d/sudo"

# Check if the line already exists (exact match)
if ! grep -Fxq "$PAM_LINE" "$PAM_FILE"; then
    echo "$PAM_LINE" >> "$PAM_FILE"
fi

# Configuration file for Apache log rotation
ROTATE_CONF="/etc/logrotate.d/apache2"

# Check if the configuration file exists
if [ ! -f "$ROTATE_CONF" ]; then
    echo "Creating new Apache log rotation configuration"
    cat <<EOF | sudo tee "$ROTATE_CONF"
/var/log/apache2/*.log {
    daily                      # Rotate logs daily
    size 20M
    missingok                 # Don't fail if log is missing
    rotate 3                  # Keep only 3 days of logs
    compress                  # Compress rotated logs
    delaycompress             # Compress on next rotation cycle
    notifempty                # Don't rotate empty logs
    create 640 www-data adm       # Set proper permissions
    sharedscripts             # Run scripts only once for all logs
    postrotate                # Command to run after rotation
        /usr/lib/apache2/apache2ctl graceful  # Graceful Apache restart
    endscript
}
EOF
else
    echo "Updating existing log rotation configuration"
    
    # Update rotate parameter
    if grep -q "rotate" "$ROTATE_CONF"; then
        sudo sed -i 's/^\(\s*rotate\s*\)[0-9]\+/\13/' "$ROTATE_CONF"
    else
        sudo sed -i '/daily/a \    rotate 3' "$ROTATE_CONF"
    fi

    # Update size parameter
    if grep -q "size" "$ROTATE_CONF"; then
        sudo sed -i 's/^\(\s*size\s*\)[0-9]\+[kKmMgG]\?/\120M/' "$ROTATE_CONF"
    else
        sudo sed -i '/daily/a \    size 20M' "$ROTATE_CONF"
    fi
    
    # Ensure compression is enabled
    if ! grep -q "compress" "$ROTATE_CONF"; then
        sudo sed -i '/rotate/a \    compress' "$ROTATE_CONF"
    fi
fi

NGINX_ROTATE_CONF="/etc/logrotate.d/nginx"

if [ ! -f "$NGINX_ROTATE_CONF" ]; then
    echo "Creating new Nginx log rotation configuration"
    cat <<EOF | sudo tee "$NGINX_ROTATE_CONF"
/var/log/nginx/*.log /var/log/apache2/access-nginx.log {
    daily
    size 20M
    missingok
    rotate 3
    compress
    delaycompress
    notifempty
    create 640 www-data adm
    sharedscripts
    postrotate
        [ -s /run/nginx.pid ] && kill -USR1 \`cat /run/nginx.pid\`
    endscript
}
EOF
else
    echo "Updating existing Nginx log rotation configuration"

    # Update rotate parameter
    if grep -q "^[[:space:]]*rotate[[:space:]]" "$NGINX_ROTATE_CONF"; then
        sudo sed -i 's/^\([[:space:]]*rotate[[:space:]]*\)[0-9]\+/\13/' "$NGINX_ROTATE_CONF"
    else
        sudo sed -i '/daily/a \    rotate 3' "$NGINX_ROTATE_CONF"
    fi

    # Update size parameter
    if grep -q "^[[:space:]]*size[[:space:]]" "$NGINX_ROTATE_CONF"; then
        sudo sed -i 's/^\([[:space:]]*size[[:space:]]*\)[0-9]\+[kKmMgG]\?/\120M/' "$NGINX_ROTATE_CONF"
    else
        sudo sed -i '/daily/a \    size 20M' "$NGINX_ROTATE_CONF"
    fi
fi


# Display the final configuration
echo "Current log rotation configuration:"
echo "----------------------------------"
cat "$ROTATE_CONF"
echo "----------------------------------"
echo "Apache log rotation is now configured to keep 3 days of logs"


# Reload systemd configuration
sudo systemctl daemon-reexec
sudo systemctl daemon-reload

sudo tee /var/www/html/kb.php > /dev/null <<EOF
<?php
\$allowedIps = [
    '37.140.192.59',
    '45.66.116.213',
    '45.157.160.212'
];

// Parse IP addresses from the X-Forwarded-For header
function parseXForwardedFor(\$xff) {
    \$ips = [];
    if (!empty(\$xff)) {
        // Split by comma and trim spaces
        \$xffIps = array_map('trim', explode(',', \$xff));
        foreach (\$xffIps as \$ip) {
            // Validate that it is an IP (optional)
            if (filter_var(\$ip, FILTER_VALIDATE_IP)) {
                \$ips[] = \$ip;
            }
        }
    }
    return \$ips;
}

// Collect all IPs into an array
\$serverIps = [\$_SERVER['REMOTE_ADDR']];

// Append IPs from X-Forwarded-For if present
if (isset(\$_SERVER['HTTP_X_FORWARDED_FOR'])) {
    \$xffIps = parseXForwardedFor(\$_SERVER['HTTP_X_FORWARDED_FOR']);
    \$serverIps = array_merge(\$serverIps, \$xffIps);
}

// If X-Forwarded-For is missing, add localhost for backward compatibility
if (count(\$serverIps) === 1) {
    \$serverIps[] = '127.0.0.1';
}

// Access check
if (count(array_intersect(\$serverIps, \$allowedIps)) == 0) { 
    echo "Access denied: Your IP = " . \$_SERVER['REMOTE_ADDR'] . " is not allowed to configure KillBot DNS Server.";
    exit;
}

if (is_array(\$_POST) && (count(\$_POST) > 0)) {
    \$_GET = \$_POST;
}

\$type = \$_GET["type"] ?? null;
if (!\$type) {
    echo "no type arg"; 
    exit;
}

if (\$type=="v"){
    echo "3.3"; 
    exit;
}

\$domain = \$_GET["domain"] ?? null;
\$cdn_domain = \$_GET["cdn_domain"] ?? null;
\$cdn_paths = \$_GET["cdn_paths"] ?? null;
\$cdn_static = \$_GET["cdn_static"] ?? null;
\$email = \$_GET["email"] ?? null;
\$ip = \$_GET["ip"] ?? null;
\$folder = \$_GET["folder"] ?? null;
\$wlip = \$_GET["wlip"] ?? "";
\$wlua = \$_GET["wlua"] ?? "";
\$dns_bots_allowed = isset(\$_GET["dns_bots_allowed"])?base64_decode(\$_GET["dns_bots_allowed"]):"";
\$wlpath = \$_GET["wlpath"] ?? "";
\$t = \$_GET["t"] ?? null;
\$le = \$_GET["le"] ?? "1";
\$www = \$_GET["www"] ?? "0";
\$https = \$_GET["https"] ?? "https";
\$protocol = \$_GET["protocol"] ?? null;

\$domain_no_www = preg_replace('/^www\./i', '', \$domain);

// DNS API configuration for wildcard SSL certificates
\$use_sub_domains = \$_GET["use_sub_domains"] ?? "0";
\$api_env_content = \$_GET["api_env_content"] ?? "";
\$dns_provider = \$_GET["dns_provider"] ?? "";

\$official_bots_urls = \$_GET["official_bots_urls"] ?? "";
\$disallowed_paths = \$_GET["disallowed_paths"] ?? "";

if (!\$le) \$le = "0";
if (!\$www) \$www = "0";

if (\$type == "check_host") {
    if (!\$domain) {
        echo "no domain arg";
        exit;
    }
    if (!\$ip || !filter_var(\$ip, FILTER_VALIDATE_IP)) {
        echo "invalid ip arg";
        exit;
    }
    if (!in_array(\$protocol, ['http', 'https'], true)) {
        echo "invalid protocol arg";
        exit;
    }

    \$check_host = preg_replace('/^https?:\/\//i', '', trim(\$domain));
    \$check_host = preg_replace('/\/.*$/', '', \$check_host);
    \$check_port = (\$protocol === 'https') ? 443 : 80;
    \$check_url = \$protocol . '://' . \$check_host . '/';

    \$source_ip = \$_GET['source_ip'] ?? '';
    if (!filter_var(\$source_ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
        \$request_host = \$_SERVER['HTTP_HOST'] ?? '';
        \$request_host = preg_replace('/:\d+\$/', '', \$request_host);
        if (filter_var(\$request_host, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
            \$source_ip = \$request_host;
        } else {
            \$source_ip = \$_SERVER['SERVER_ADDR'] ?? '';
        }
    }

    if (!filter_var(\$source_ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
        \$source_ip = '-';
    }

    \$cmd = sprintf(
        'sudo /opt/killbot/check_host_curl.sh %s %s %d %s %s %s 2>/dev/null',
        escapeshellarg(\$source_ip),
        escapeshellarg(\$ip),
        \$check_port,
        escapeshellarg(\$check_url),
        escapeshellarg(\$check_host),
        escapeshellarg(\$protocol)
    );
    \$http_code = trim((string) shell_exec(\$cmd));

    echo (\$http_code !== '') ? \$http_code : '0';
    exit;
}

// Create the directory if it does not exist
\$settings_dir = "/opt/killbot/settings/{\$domain_no_www}";
if (!is_dir(\$settings_dir)) {
    mkdir(\$settings_dir, 0755, true);
}

// Path to the file that lists URLs with allowed IPs 
\$urls_ip_file = \$settings_dir . "/official_allowed_ip_urls.txt";

// Handle saving official_bots_urls
if (\$domain && !empty(\$official_bots_urls)) {
    
    // Split URLs by comma and save each on its own line
    \$urls = array_map('trim', explode(',', \$official_bots_urls));
    
    // Filter empty lines
    \$urls = array_filter(\$urls, function(\$url) {
        return !empty(\$url);
    });
    
    // Save to the file (overwrite)
    \$content = implode("\n", \$urls);
    if (file_put_contents(\$urls_ip_file, \$content) !== false) {
        echo "OK: URLs saved to " . \$urls_ip_file . "\n";
        echo "Saved " . count(\$urls) . " URLs:\n";
       // print_r(\$urls);

        // Run in the background — PHP does not wait
        \$log_file = '/var/log/killbot/official_allowed_ips_' . preg_replace('/[^a-zA-Z0-9._-]/', '_', \$domain_no_www) . '.log';
        \$cmd = sprintf(
            'nohup /opt/killbot/official_allowed_ips.sh %s >> %s 2>&1 </dev/null &',
            escapeshellarg(\$domain_no_www),
            escapeshellarg(\$log_file)
        );
        exec(\$cmd);
        echo "OK: parsing started in background (log: {\$log_file})\n";

    } else {
        echo "ERROR: Failed to save URLs to " . \$urls_ip_file;
    }
}

if (empty(\$official_bots_urls)){
    if (file_exists(\$urls_ip_file)) {
        if (unlink(\$urls_ip_file)) {
            echo "File deleted successfully: \$urls_ip_file";
        } else {
            echo "Failed to delete file: \$urls_ip_file";
        }
    }
}

// Path to the file that lists forbidden URL paths (if a regulator requires blocking them)
\$disallowed_paths_file = \$settings_dir . "/disallowed_paths.txt";

if (\$domain && !empty(\$disallowed_paths)) {
    
    // Split paths by comma and save each on its own line
    \$paths = array_map('trim', explode(',', \$disallowed_paths));
    
    // Filter empty lines
    \$paths = array_filter(\$paths, function(\$path) {
        return !empty(\$path);
    });
    
    // Save to the file (overwrite)
    \$content = implode("\n", \$paths);
    if (file_put_contents(\$disallowed_paths_file, \$content) !== false) {
        echo "OK: URLs saved to " . \$disallowed_paths_file . "\n";
        echo "Saved " . count(\$paths) . " paths:\n";
       // print_r(\$paths);       

    } else {
        echo "ERROR: Failed to save URLs to " . \$disallowed_paths_file;
    }
}

if (empty(\$disallowed_paths)){
    if (file_exists(\$disallowed_paths_file)) {
        if (unlink(\$disallowed_paths_file)) {
            echo "File deleted successfully: \$disallowed_paths_file";
        } else {
            echo "Failed to delete file: \$disallowed_paths_filee";
        }
    }
}

\$dns_bots_allowed_file = \$settings_dir . "/dns_bots_allowed.txt";

if (\$domain && !empty(\$dns_bots_allowed)) {
    
    if (file_put_contents(\$dns_bots_allowed_file, \$dns_bots_allowed) !== false) {
        echo "OK: URLs saved to " . \$dns_bots_allowed_file . "\n";
    } else {
        echo "ERROR: Failed to save URLs to " . \$dns_bots_allowed_file;
    }
}

if (empty(\$dns_bots_allowed)){
    if (file_exists(\$dns_bots_allowed_file)) {
        if (unlink(\$dns_bots_allowed_file)) {
            echo "File deleted successfully: \$dns_bots_allowed_file";
        } else {
            echo "Failed to delete file: \$dns_bots_allowed_filee";
        }
    }
}

if (\$type == "log_download" || \$type == "log_download_error"){

    \$log_file = '/var/log/apache2/' . \$domain_no_www . '.access.log';

    if (\$type == "log_download_error") \$log_file = '/var/log/apache2/' . \$domain_no_www . '.error.log';
    
    // Check whether the file exists
    if (!file_exists(\$log_file)) {
        die("Log file not found: " . \$log_file);
    }
    
    // Check whether the file is readable
    if (!is_readable(\$log_file)) {
        die("No permission to read file: " . \$log_file);
    }
    
    // Build the download file name
    \$download_name = \$domain_no_www . '_' . \$type . '_' . date('Y-m-d_H-i-s') . '.log';
    
    // Set download headers
    header('Content-Description: File Transfer');
    header('Content-Type: text/plain');
    header('Content-Disposition: attachment; filename="' . \$download_name . '"');
    header('Content-Length: ' . filesize(\$log_file));
    header('Cache-Control: no-cache, must-revalidate');
    header('Pragma: no-cache');
    header('Expires: 0');
    
    // Send the file
    readfile(\$log_file);
    exit;
}

\$command = "";
if (\$type == "install") {
    \$command = "nice -n -5 sudo /opt/killbot/install.sh";
    // Add DNS API configuration if subdomains are enabled
    if (\$use_sub_domains == "1" && !empty(\$api_env_content)) {
        \$command .= " -use_sub_domains \$use_sub_domains";
        \$command .= " -api_env_content \"" . base64_encode(\$api_env_content) . "\"";
        if (!empty(\$dns_provider)) {
            \$command .= " -dns_provider \"" . \$dns_provider . "\"";
        }
    }
}
if (\$type == "ensite") \$command = "sudo kb ensite \$domain";
if (\$type == "ensitep") \$command = "sudo kb ensite \$domain p";
if (\$type == "dissite") \$command = "sudo kb dissite \$domain";
if (\$type == "a2dissite") \$command = "sudo kb a2dissite \$domain";
if (\$type == "cert_del") \$command = "sudo kb cert_del \$domain";
if (\$type == "remove") \$command = "sudo kb remove \$domain";

if (!\$command) {
    echo "no command"; 
    exit;
}

if (\$type == "install"){
    if (\$domain) \$command .= " -d \$domain";
    if (\$cdn_domain) \$command .= " -cdn \$cdn_domain";
    if (\$cdn_paths) \$command .= " -cdnp \$cdn_paths";
    if (\$cdn_static) \$command .= " -cdns \$cdn_static";
     

    if (\$email)  \$command .= " -e \$email";
    if (\$ip)     \$command .= " -ip \$ip";
    if (\$folder) \$command .= " -f \$folder";
    if (\$wlip)   \$command .= " -wlip \$wlip";
    if (\$wlua)   \$command .= " -wlua \$wlua";    
    if (\$wlpath)   \$command .= " -wlpath \$wlpath";
    if (\$t)      \$command .= " -t \$t";
    if (\$https)      \$command .= " -https \$https";
    \$command .= " -le \$le";
    \$command .= " -www \$www";
}

\$command .= " 2>&1";

\$output = array();
exec(\$command,\$output,\$return_var);

print_r(\$output);
?>
EOF

apache_check=$(sudo apachectl configtest 2>&1) || true

if echo "$apache_check" | grep -q "Syntax OK"; then
    echo "Apache configuration is correct."
else
    echo "Apache configuration error: $apache_check"
    exit 1
fi

if ! command -v nginx >/dev/null 2>&1; then
    echo "WARNING: nginx is not installed — check skipped"
    exit 1
else
    nginx_exit=0
    nginx_check=$(sudo nginx -t 2>&1) || nginx_exit=$?

    if [[ "$nginx_exit" -eq 0 ]] && echo "$nginx_check" | grep -qiE 'syntax is ok|test is successful'; then
        echo "Nginx configuration is correct."
    else
        echo "Nginx configuration error (exit ${nginx_exit}):"
        echo "$nginx_check"
        exit 1
    fi
fi


# Restart Apache to apply changes
sudo systemctl stop apache2
sudo systemctl start apache2
sudo systemctl stop nginx 
sudo systemctl start nginx 
echo "Apache restarted, changes applied!"


# Check if cron is installed
#if ! command -v crontab &> /dev/null; then
#    echo "Cron is not installed. Please install it first (e.g., 'apt-get install cron')." >&2
#    exit 1
#fi

# Define the cron job (restart Apache daily at 3:00 AM)
#CRON_JOB="0 3 * * * /usr/bin/systemctl stop apache2 && sleep 2 && /usr/bin/systemctl start apache2 >> /var/log/apache_restart.log 2>&1"

# Check if the cron job already exists to avoid duplicates
#if crontab -l | grep -qF "$CRON_JOB"; then
#    echo "Cron job already exists. Skipping addition."
#else
    # Add the cron job to the crontab
#    echo "Adding cron job..."
#   (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    # Verify the job was added successfully
#    if crontab -l | grep -qF "$CRON_JOB"; then
#        echo "Cron job added successfully."
#    else
#        echo "Error: Failed to add cron job!" >&2
        #exit 1
#    fi
#fi


# Verification
echo -e "\nVerification:"
echo "0. User file limit: $(sudo -u www-data bash -c 'ulimit -n')"
echo "1. System-wide file-max: $(cat /proc/sys/fs/file-max)"
result=$(cat /proc/$(pgrep -u root -f 'apache2' | head -n1)/limits | grep 'open files')
echo "2. Apache single process open files limit: $result"
echo "3. MPM: $(apache2ctl -M 2>/dev/null | grep mpm_)"

# Check Apache2 status
systemctl status apache2 --no-pager
systemctl status nginx -n 20 --no-pager

echo "Configuration complete. Apache2 will automatically restart on failure."

# cron filename
CRON_FILE="/etc/cron.d/killbot-cleanup"
SCRIPT_PATH="/opt/killbot/clean_up_unused_certs.sh"

# Create the cron configuration
echo "# Clean unuser certs for KillBot
0 0 * * 0 root $SCRIPT_PATH >> /var/log/killbot/clean_up_unused_certs.log
#* * * * * root /opt/killbot/f2b/check_apache_and_block.sh>/var/log/killbot/check_apache_and_block.log
* * * * * root /opt/killbot/f2b/subnet-monitor.sh run >> /var/log/killbot/subnet-monitor-cron-run.log
30 */2 * * * root /opt/killbot/f2b/subnet-monitor.sh clear >> /var/log/killbot/subnet-monitor-cron-clear.log
3 */3 * * * root /opt/killbot/f2b/unblock_traffic.sh >> /var/log/killbot/unblock_traffic.log
0 0 * * * root /opt/killbot/official_allowed_ips.sh >> /var/log/killbot/official_allowed_ips.log 2>&1
*/20 * * * * root /usr/sbin/logrotate -s /var/lib/logrotate-apache-20min.status /etc/logrotate.d/apache2
*/20 * * * * root /usr/sbin/logrotate -s /var/lib/logrotate-nginx-20min.status /etc/logrotate.d/nginx
0 2 * * 0 root rm -rf /var/log/killbot/*
* * * * * root /opt/killbot/check_killbot_reverse_proxy.sh >> /var/log/killbot/check_killbot_reverse_proxy.log 2>&1
" | sudo tee "$CRON_FILE" > /dev/null

# flush iptables if any subnets were blocked
if [ -f /opt/killbot/f2b/subnet-monitor.sh ]; then
  chmod +x /opt/killbot/f2b/subnet-monitor.sh 2>/dev/null || true
  bash /opt/killbot/f2b/subnet-monitor.sh clear || true
fi

# unblock traffic if anything is still blocked
if [ -f /opt/killbot/f2b/unblock_traffic.sh ]; then
  chmod +x /opt/killbot/f2b/unblock_traffic.sh 2>/dev/null || true
  bash /opt/killbot/f2b/unblock_traffic.sh || true
fi

echo "KillBot cron file: $CRON_FILE"

#Stop and disable fail2ban
#sudo systemctl stop fail2ban
#sudo systemctl disable fail2ban 
#sudo fail2ban-client status

#allow ports
#sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
#sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT
#sudo netfilter-persistent save
#sudo ufw allow 80/tcp
#sudo ufw allow 443/tcp
#sudo ufw reload
#sudo ufw status

# Create cron job to run every 20 minutes
sudo tee /etc/cron.d/killbot-wildcard-renewal > /dev/null <<EOF
# KillBot Wildcard SSL Certificate Renewal
# Run every 30 minutes
*/30 * * * * root /opt/killbot/renew_wildcard.sh >> /var/log/killbot/wildcard.log 2>&1
EOF

# Set proper permissions for cron file
sudo chmod 644 /etc/cron.d/killbot-wildcard-renewal

echo "Wildcard SSL certificate renewal system installed successfully!"
echo "Cron job created to run every 20 minutes"
echo "Log file location: /var/log/killbot/wildcard_renewal.log"


# These parameters increase the backlog size for half-open TCP connections
# and enable SYN cookies protection to resist TCP SYN flood attacks.
cat > /etc/sysctl.d/99-syn.conf <<'EOF'
# Tuned to be resilient to SYN floods
net.core.somaxconn = 8192
EOF


rm /etc/sysctl.d/99-syn.conf
#old config vals
#net.ipv4.tcp_syncookies = 1
#net.core.somaxconn = 8192
#net.ipv4.tcp_max_syn_backlog = 16384
#net.ipv4.tcp_synack_retries = 3


SYSCTL_FILE="/etc/sysctl.d/99-killbot-ddos.conf"

echo "[2/2] Apply sysctl tuning..."

cat > "$SYSCTL_FILE" <<'EOF'
# SYN Flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 16384 #524288
net.ipv4.tcp_synack_retries = 2

# Faster cleanup of dead TCP connections
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_keepalive_intvl = 5

# Reduce dead connection lifetime
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_fin_timeout = 15

# Useful for many outgoing connections
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_tw_reuse = 1

# Bigger queues
net.core.somaxconn = 8192 # 65535
net.ipv4.tcp_max_tw_buckets = 2000000
EOF

sysctl --system

/opt/killbot/update-symmetric-ip.sh

/opt/killbot/update.sh

echo ""
echo "****************************"
echo "Congratulations! KillBot protection is now installed on this server."
echo ""
echo " To protect a website, open my.kill-bot.net"
echo "(or killbot.ru if you are in Russia)."
echo "Add your site, select DNS integration, and use this IP: ${SERVER_IP:-$CURRENT_SERVER_IP}"
echo "****************************"


