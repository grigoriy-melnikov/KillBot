#!/usr/bin/env bash
# renew_wildcard.sh
# Automatic check/issue of wildcard certs via acme.sh

set -euo pipefail

if pgrep -f "certbot" > /dev/null; then
    echo "$(date '+%F %T') - Certbot process is already running, exiting"
    exit 0
fi

LOGFILE="/var/log/renew_wildcard.log"
CERTS_DIR="/opt/killbot/certs"
LE_DIR="/etc/letsencrypt/live"
ACME_BIN="/root/.acme.sh/acme.sh"
RELOAD_CMD="systemctl reload apache2"

mkdir -p "$(dirname "$LOGFILE")"
log() { echo "$(date '+%F %T') - $*" >> "$LOGFILE"; echo "$(date '+%F %T') - $*"; }

is_wildcard_cert() {
  local certfile="$1"
  local domain="$2"
  if [[ ! -f "$certfile" ]]; then return 1; fi

  mapfile -t dns_entries < <(openssl x509 -in "$certfile" -noout -text 2>/dev/null | grep -oP 'DNS:[^,]+' | sed 's/^DNS://')
  for n in "${dns_entries[@]}"; do
    if [[ "$n" == "*.$domain" ]]; then
      return 0
    fi
  done
  return 1
}

# Function to get DNS hook based on provider name
get_dns_hook_by_provider() {
    local provider="$1"

    case "$provider" in
        "regru")
            echo "dns_regru"
            ;;
        "cloudflare")
            echo "dns_cf"
            ;;
        "godaddy")
            echo "dns_gd"
            ;;
        "namecheap")
            echo "dns_namecheap"
            ;;
        "digitalocean")
            echo "dns_do"
            ;;
        "aws"|"route53")
            echo "dns_aws"
            ;;
        "beget")
            echo "dns_beget"
            ;;
        "timeweb")
            echo "dns_timeweb"
            ;;
        "sprinthost")
            echo "dns_sprinthost"
            ;;
        "spaceweb")
            echo "dns_spaceweb"
            ;;
        "fornex")
            echo "dns_fornex"
            ;;
        "adminvps")
            echo "dns_adminvps"
            ;;
        *)
            echo "dns_$provider"
            ;;
    esac
}

detect_dns_hook_and_dnssleep() {
    local api_env_file="$1"
    local domain_dir=$(dirname "$api_env_file")
    local domain=$(basename "$domain_dir")
    local provider_file="$domain_dir/provider"
    
    echo "DEBUG: detect_dns_hook_and_dnssleep called with api_env_file=$api_env_file" >&2
    echo "DEBUG: domain_dir=$domain_dir, domain=$domain, provider_file=$provider_file" >&2

    if [[ ! -f "$provider_file" ]]; then
        echo "No provider file found for $domain: $provider_file" >&2
        echo "unknown:1500"
        return 1
    fi

    local dns_provider=$(cat "$provider_file" | tr -d '\r\n')
    echo "Found DNS provider for $domain: $dns_provider" >&2

    # Use the existing function
    local dns_hook=$(get_dns_hook_by_provider "$dns_provider")
    echo "DNS hook for $domain: $dns_hook" >&2

    if [[ ! -f "/root/.acme.sh/dnsapi/$dns_hook.sh" ]]; then
        echo "ERROR: Unknown DNS provider '$dns_provider' for $domain - no corresponding hook found" >&2
        echo "Supported providers: regru, cloudflare, godaddy, namecheap, digitalocean, aws, beget, timeweb, sprinthost, spaceweb, fornex, adminvps" >&2
        echo "unknown:1500"
        return 2  # Special return code for an unknown provider
    else
        echo "${dns_hook}:1500"
    fi
}

log "Starting wildcard SSL certificate check and renewal process"

# Check for command line arguments
if [[ "${1:-}" == "--reset-enabled" ]]; then
  log "Reset mode: removing all enabled files to force retry"
  find "$CERTS_DIR" -name "enabled" -type f -delete 2>/dev/null || true
  log "All enabled files removed - forcing retry for all domains"
fi

for domain_dir in "$CERTS_DIR"/*; do
  [[ -d "$domain_dir" ]] || continue
  domain=$(basename "$domain_dir")
  api_env="$domain_dir/api.env"
  enabled_file="$domain_dir/enabled"

  if [[ ! -f "$api_env" ]]; then
    log "No DNS API configuration found for $domain, skipping"
    continue
  fi

  # Check if certificate issuance is disabled due to previous persistent errors
  if [[ -f "$enabled_file" ]]; then
    enabled_value=$(cat "$enabled_file" 2>/dev/null || echo "1")
    if [[ "$enabled_value" = "0" ]]; then
      log "Certificate issuance disabled for $domain due to previous persistent errors, skipping"
      log "To force retry, run: /opt/killbot/renew_wildcard.sh --reset-enabled"
      log "Or manually remove: rm /opt/killbot/certs/$domain/enabled"
      continue
    else
      log "Certificate issuance enabled for $domain (enabled=$enabled_value)"
    fi
  else
    log "No enabled file found for $domain - allowing certificate issuance"
  fi

  log "Found domain with DNS API configuration: $domain"

  cert_path="$LE_DIR/$domain/fullchain.pem"
  need_issue=false
  force_renew=false

  if [[ ! -f "$cert_path" ]]; then
    log "No existing Let's Encrypt cert found for $domain -> will issue wildcard"
    need_issue=true
  else
    if is_wildcard_cert "$cert_path" "$domain"; then
      # Existing certificate is ALREADY a wildcard — check expiry
      end_date=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
      if [[ -n "$end_date" ]]; then
        end_epoch=$(date -d "$end_date" +%s)
        now_epoch=$(date +%s)
        days_left=$(( (end_epoch - now_epoch) / 86400 ))
        log "Certificate for $domain is wildcard and expires in $days_left days"
        if (( days_left < 25 )); then
          log "Less than 25 days until expiration -> will renew wildcard"
          need_issue=true
        fi
      else
        log "Cannot read certificate expiration date for $domain - will renew"
        need_issue=true
      fi
    else
      # EXISTING CERTIFICATE IS NOT A WILDCARD — FORCE RENEW!
      log "Existing certificate for $domain is NOT wildcard -> FORCING wildcard issuance now"
      need_issue=true
      force_renew=true  # SET THE FORCE-RENEW FLAG
    fi
  fi

  if [[ "$need_issue" = true ]]; then
    log "DEBUG: About to call detect_dns_hook_and_dnssleep for $domain"
    hook_and_sleep=$(detect_dns_hook_and_dnssleep "$api_env")
    hook_exit_code=$?
    log "DEBUG: detect_dns_hook_and_dnssleep returned: hook_and_sleep='$hook_and_sleep', exit_code=$hook_exit_code"
    
    if [[ $hook_exit_code -eq 1 ]]; then
      # provider file not found — create enabled=0 and skip
      log "No provider file found for $domain - disabling future attempts"
      echo "0" > "$enabled_file"
      chmod 644 "$enabled_file"
      log "Created enabled file with value 0 for $domain due to missing provider file"
      log "DEBUG: enabled_file=$enabled_file, content=$(cat "$enabled_file")"
      continue
    elif [[ $hook_exit_code -eq 2 ]]; then
      # Unknown DNS provider — create enabled=0 and skip
      log "Unknown DNS provider detected for $domain - disabling future attempts"
      echo "0" > "$enabled_file"
      chmod 644 "$enabled_file"
      log "Created enabled file with value 0 for $domain due to unknown DNS provider"
      log "DEBUG: enabled_file=$enabled_file, content=$(cat "$enabled_file")"
      continue
    fi
    
    DNS_HOOK="${hook_and_sleep%%:*}"
    DNSSLEEP="${hook_and_sleep##*:}"
    
    # Ensure the DNS hook is not "unknown"
    if [[ "$DNS_HOOK" == "unknown" ]]; then
      log "ERROR: No valid DNS hook found for $domain - skipping certificate issuance"
      echo "0" > "$enabled_file"
      chmod 644 "$enabled_file"
      log "Created enabled file with value 0 for $domain due to missing DNS hook"
      continue
    fi
    
    log "Using DNS hook: $DNS_HOOK with dnssleep=$DNSSLEEP for $domain"

    # Build the acme.sh command
    acme_cmd=(
      "$ACME_BIN" --issue
      -d "$domain" -d "*.$domain"
      --dns "$DNS_HOOK"
      --dnssleep "$DNSSLEEP"
      --key-file "$LE_DIR/$domain/privkey.pem"
      --fullchain-file "$LE_DIR/$domain/fullchain.pem"
      --reloadcmd "$RELOAD_CMD"
      --server https://acme-v02.api.letsencrypt.org/directory
      --force
    )

    # IF THE CERT EXISTS AND IS NOT A WILDCARD — ADD --force
    if [[ "$force_renew" = true ]]; then
      acme_cmd+=(--force)
      log "Adding --force flag to replace non-wildcard certificate"
    fi

    log "Full acme.sh command: ${acme_cmd[*]}"

    acme_output=$(mktemp)
    acme_exit_code=0

    (
      set -a
      source "$api_env"
      set +a
      "${acme_cmd[@]}" > "$acme_output" 2>&1
    ) || acme_exit_code=$?

    cat "$acme_output" | tee -a "$LOGFILE"

    if [[ $acme_exit_code -ne 0 ]]; then
      log "acme.sh returned error for $domain (exit code: $acme_exit_code)"

      # Analyze the error and classify it
      if grep -qi "Skipping. Next renewal time is:" "$acme_output"; then
        log "Certificate renewal skipped due to Let's Encrypt rate limits"
        log "This is normal - script will retry later automatically"
        # Do not create an enabled file for temporary Let's Encrypt errors
      elif grep -qiE "(too many requests|rate limit|try again later|server.*unavailable|connection.*refused|timeout)" "$acme_output"; then
        log "Temporary Let's Encrypt server error - will retry next time"
        log "This appears to be a temporary issue that may resolve automatically"
        # Do not create an enabled file for temporary server errors
      elif grep -qiE "(DNS|API|authentication|credential|permission|access|invalid|forbidden|unauthorized|not supported|policy|disallowed|rejected)" "$acme_output"; then
        log "Persistent error detected for $domain - disabling future attempts"
        echo "0" > "$enabled_file"
        chmod 644 "$enabled_file"
        log "Created enabled file with value 0 for $domain"
        
        # Log error details
        error_detail=$(grep -iE "(DNS|API|authentication|credential|permission|access|invalid|forbidden|unauthorized|not supported|policy|disallowed|rejected)" "$acme_output" | head -1)
        log "Error details: $error_detail"
      else
        log "Unknown error type for $domain - will retry next time"
        log "Error output: $(head -3 "$acme_output")"
      fi
    else
      # Certificate obtained successfully
      echo "1" > "$enabled_file"
      chmod 644 "$enabled_file"
      log "Wildcard certificate successfully issued/renewed for $domain"
      log "Created enabled file with value 1 for $domain"
    fi

    rm -f "$acme_output"
  fi
done

log "Wildcard SSL certificate check and renewal process completed"