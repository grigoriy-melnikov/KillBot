#!/usr/bin/env bash
# delete_cert.sh — deletes a Let's Encrypt certificate via certbot
# Usage:
#   sudo ./delete_cert.sh example.com
#   sudo ./delete_cert.sh example.com do_not_reload do_not_remove_ssl_path

check_nginx() {
    if command -v nginx &> /dev/null; then
        return 0
    else
        return 1
    fi
}

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <domain> [do_not_reload] [do_not_remove_ssl_path]"
  exit 1
fi

DOMAIN="$1"
shift

SKIP_RELOAD=0
SKIP_SSL_PATH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    do_not_reload)
      SKIP_RELOAD=1
      ;;
    do_not_remove_ssl_path)
      SKIP_SSL_PATH=1
      ;;
    *)
      echo "Unknown parameter: $1"
      exit 1
      ;;
  esac
  shift
done

SSL_DIR="/opt/killbot/ssl/${DOMAIN}"

# Delete the certificate without a prompt
certbot delete --cert-name "$DOMAIN" --non-interactive

if [[ "$SKIP_SSL_PATH" -eq 0 ]]; then
    if [[ -n "$DOMAIN" && "$DOMAIN" != *"/"* && "$DOMAIN" != *".."* ]]; then
        if [[ -d "$SSL_DIR" ]]; then
            rm -rf "$SSL_DIR"
            echo "Removed: $SSL_DIR"
        fi
    fi
else
    echo "Skip remove SSL path: $SSL_DIR"
fi

sudo rm -f "/etc/nginx/sites-enabled/$DOMAIN.conf"
sudo rm -f "/etc/nginx/sites-enabled/000-r1.$DOMAIN.conf"
sudo rm -f "/etc/nginx/sites-enabled/000-r2.$DOMAIN.conf"
sudo rm -f "/etc/nginx/sites-enabled/000-r3.$DOMAIN.conf"
sudo rm -f "/etc/nginx/sites-enabled/000-r4.$DOMAIN.conf"
sudo rm -f "/etc/nginx/sites-enabled/000-r5.$DOMAIN.conf"
sudo rm -f "/etc/nginx/sites-enabled/000-r6.$DOMAIN.conf"

sudo rm -f "/etc/nginx/sites-available/$DOMAIN.conf"
sudo rm -f "/etc/nginx/sites-available/000-r1.$DOMAIN.conf"
sudo rm -f "/etc/nginx/sites-available/000-r2.$DOMAIN.conf"
sudo rm -f "/etc/nginx/sites-available/000-r3.$DOMAIN.conf"
sudo rm -f "/etc/nginx/sites-available/000-r4.$DOMAIN.conf"
sudo rm -f "/etc/nginx/sites-available/000-r5.$DOMAIN.conf"
sudo rm -f "/etc/nginx/sites-available/000-r6.$DOMAIN.conf"

a2dissite "$DOMAIN"
a2dissite "$DOMAIN-killbot"
sudo rm -f "/etc/apache2/sites-available/$DOMAIN.conf"
sudo rm -f "/etc/apache2/sites-available/$DOMAIN-killbot.conf"

if [[ "$SKIP_RELOAD" -eq 1 ]]; then
  echo "Skip reload apache2/nginx (batch mode)"
  exit 0
fi

if apache2ctl configtest >/dev/null 2>&1; then
  service apache2 reload
else
  echo "[ERROR] Apache config invalid; skip reload. Run: apache2ctl configtest" >&2
  apache2ctl configtest >&2 || true
fi

if check_nginx; then
    sudo systemctl reload nginx
fi
