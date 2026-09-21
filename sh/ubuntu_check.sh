#!/bin/bash

set -e

echo "=== System check ==="

# 1. Check Ubuntu 22.04
if [ ! -f /etc/os-release ]; then
    echo "ERROR: Cannot detect OS"
    exit 1
fi

. /etc/os-release

if [ "$ID" != "ubuntu" ]; then
    echo "ERROR: Not Ubuntu (detected: $ID)"
    exit 1
fi

if [ "$VERSION_ID" != "22.04" ]; then
    echo "ERROR: Ubuntu 22.04 required (detected: $VERSION_ID)"
    exit 1
fi

echo "OK: Ubuntu 22.04 detected"


# 2. Check for control panels / frameworks
echo "=== Control panel check ==="

FOUND=0

check_process() {
    local name="$1"
    if pgrep -f "$name" >/dev/null 2>&1; then
        echo "ERROR: Process detected: $name"
        FOUND=1
    fi
}

check_path() {
    local path="$1"
    if [ -e "$path" ]; then
        echo "ERROR: Found path: $path"
        FOUND=1
    fi
}

# ISPmanager
check_process "ispmgr"
check_path "/usr/local/mgr5"

# VestaCP
check_process "vesta"
check_path "/usr/local/vesta"

# HestiaCP
check_process "hestia"
check_path "/usr/local/hestia"

# cPanel
check_process "cpanel"
check_path "/usr/local/cpanel"

# Plesk
check_process "plesk"
check_path "/usr/local/psa"

# aaPanel
check_process "bt"
check_path "/www/server/panel"

# Webmin
check_process "webmin"
check_path "/etc/webmin"

if [ "$FOUND" -ne 0 ]; then
    echo "ERROR: Control panel detected. Clean server required."
    exit 1
fi

echo "OK: No control panels detected"