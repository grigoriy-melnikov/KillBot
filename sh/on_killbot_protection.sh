#!/bin/bash

# Directory where Let's Encrypt certificates are stored
LE_DIR="/etc/letsencrypt/live"

# Check whether the directory exists
if [ ! -d "$LE_DIR" ]; then
  echo "Directory $LE_DIR not found!"
  exit 1
fi

count=0
max_sites=900

# Iterate all directories (domains) inside the folder
for domain_path in "$LE_DIR"/*/; do

  ((count++))
  if (( count > max_sites )); then
    echo "Reached the limit of $max_sites sites. Stopping."
    break
  fi

  # Get the domain name from the path
  domain=$(basename "$domain_path")

  echo "Processing domain: $domain"

  # Disable the -killbot site
  if a2dissite "${domain}" 2>/dev/null; then
    echo "Disabled ${domain}"
  else
    echo "Failed to disable ${domain} (may not exist or already disabled)"
  fi

  # Enable the regular site
  if a2ensite "$domain-killbot" 2>/dev/null; then
    echo "Enabled $domain-killbot"
  else
    echo "Failed to enable $domain-killbot (may already be enabled or the file is missing)"
  fi

#exit 1

  echo
done

systemctl reload apache2

echo "Ready."

