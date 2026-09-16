#!/bin/bash

# Global cache URL -> IP ranges
declare -A URL_CACHE

# Process a single domain
process_domain() {
    local domain="$1"
    local urls_file="/opt/killbot/settings/${domain}/official_allowed_ip_urls.txt"
    local output_file="/opt/killbot/settings/${domain}/official_allowed_ips_genetated.txt"
    
    echo "Processing domain: $domain"
    
    # Check that the URL file exists
    if [ ! -f "$urls_file" ]; then
        echo "  File not found: $urls_file"
        return 1
    fi
    
    # Create a temp file to collect all IP ranges
    local temp_file=$(mktemp)
    
    # Read URLs from the file and process each
    while IFS= read -r url || [ -n "$url" ]; do
        # Skip empty lines and comments
        if [[ -z "$url" || "$url" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        
        # Trim spaces
        url=$(echo "$url" | tr -d '[:space:]')
        
        echo "  URL: $url"
        
        # 🔹 Check the cache
        if [[ -n "${URL_CACHE[$url]}" ]]; then
            echo "    → using cache"
            echo "${URL_CACHE[$url]}" >> "$temp_file"
            continue
        fi
        
        echo "    → requesting the server"
        
        # Make the request
        response=$(curl -s --max-time 10 "$url")
        
        if [ $? -ne 0 ] || [ -z "$response" ]; then
            echo "    Failed to fetch $url"
            # cache an empty value so we do not hit it again
            URL_CACHE[$url]=""
            continue
        fi
        
        # Parse JSON
        prefixes=$(echo "$response" | jq -r '.prefixes[]?.ipv4Prefix // empty' 2>/dev/null)
        
        # Save to cache (even if empty)
        URL_CACHE[$url]="$prefixes"
        
        # Append to the temp file
        if [[ -n "$prefixes" ]]; then
            echo "$prefixes" >> "$temp_file"
        fi
        
    done < "$urls_file"
    
    # Check whether any IP ranges were found
    if [ -s "$temp_file" ]; then
        # Sort and unique
        sort -u "$temp_file" > "$output_file"
        local count=$(wc -l < "$output_file")
        echo "  Saved $count IP ranges to: $output_file"
    else
        echo "  No IP ranges found"
        > "$output_file"
    fi
    
    # Remove the temp file
    rm -f "$temp_file"
    
    return 0
}

# Main logic
if [ $# -eq 1 ]; then
    # If an argument is given — process a single domain
    domain="$1"
    process_domain "$domain"
else
    echo "No argument given, looking for domains in /etc/nginx/sites-enabled/"
    
    # Check the directory
    if [ ! -d "/etc/nginx/sites-enabled" ]; then
        echo "Error: directory /etc/nginx/sites-enabled not found"
        exit 1
    fi
    
    domains=()
    
    # Get the domain list
    for conf_file in /etc/nginx/sites-enabled/*.conf; do
        if [ -f "$conf_file" ]; then
            filename=$(basename "$conf_file" .conf)
            domains+=("$filename")
        fi
    done
    
    if [ ${#domains[@]} -eq 0 ]; then
        echo "No .conf files found in /etc/nginx/sites-enabled/"
        exit 1
    fi
    
    echo "Domains found: ${#domains[@]}"
    
    # Process each domain
    for domain in "${domains[@]}"; do
        process_domain "$domain"
        echo ""
    done
fi

echo "Done!"