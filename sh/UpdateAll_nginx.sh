wget https://data.kill-bot.net/killbot_dns/kb_install.sh -O kb_install.sh
chmod +x kb_install.sh
yes '' | sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a ./kb_install.sh
#/opt/killbot/update.sh