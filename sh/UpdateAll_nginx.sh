#!/bin/bash
set -e
rm -f kbi.sh
rm -f kb_install.sh
wget -O kbi.sh https://raw.githubusercontent.com/grigoriy-melnikov/KillBot/main/kb_install.sh
chmod +x kbi.sh
yes '' | sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a ./kbi.sh
