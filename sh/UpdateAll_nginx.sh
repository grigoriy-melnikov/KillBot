#!/bin/bash
set -e

INSTALLER_URL="https://raw.githubusercontent.com/grigoriy-melnikov/KillBot/main/kb_install.sh"
INSTALLER_TMP="/tmp/killbot-kb_install.sh"

rm -f "$INSTALLER_TMP"
timeout 15 curl --connect-timeout 10 -f -L \
  -H "Cache-Control: no-cache" -H "Pragma: no-cache" \
  -o "$INSTALLER_TMP" "$INSTALLER_URL"

chmod +x "$INSTALLER_TMP"
rm -f ./kbi.sh ./kb_install.sh 2>/dev/null || true
cp -f "$INSTALLER_TMP" ./kbi.sh 2>/dev/null || true
cp -f "$INSTALLER_TMP" ./kb_install.sh 2>/dev/null || true
chmod +x ./kbi.sh ./kb_install.sh 2>/dev/null || true

yes '' | sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a "$INSTALLER_TMP"
#/opt/killbot/update.sh
