#!/bin/bash

# Check the number of arguments
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <domain> <email>"
    exit 1
fi

DOMAIN=$1
EMAIL=$2

# Check whether certbot is installed
if ! command -v certbot &> /dev/null; then
    echo "Certbot is not installed. Install it first:"
    echo "sudo apt update && sudo apt install certbot -y"
    exit 1
fi

# Issue the certificate
sudo certbot certonly --manual \
    --preferred-challenges=dns \
    --cert-name "$DOMAIN" \
    -d "$DOMAIN" \
    -d "*.$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --manual-public-ip-logging-ok \
    --expand

# Check the result
if [ $? -eq 0 ]; then
    echo "Certificate for $DOMAIN issued successfully!"
else
    echo "An error occurred while issuing the certificate."
fi

