wget https://raw.githubusercontent.com/grigoriy-melnikov/KillBot/main/kb_install.sh -O kb_install.sh
chmod +x kb_install.sh
yes '' | sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a ./kb_install.sh
#/opt/killbot/update.sh