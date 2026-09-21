# KillBot DNS Verification page

Install KillBot’s DNS verification page on **Ubuntu 22.04**.

Run it on a separate server in front of your site. Visitors land on this box first, pass a short JavaScript check, then get sent on to the real website.

People usually only see that page **about once a day**. It’s a JS challenge, so it stops:

- bots that behave like a real person in a browser
- basic HTTP bots, scanners, and L7 DDoS tools that can’t run JavaScript

Just want to protect a site? Install this, add the domain in the KillBot dashboard, and you’re done. Skip the file list unless you need it.

## How it works

1. Set the domain’s A record to this server’s IP.
2. Nginx and Apache on this box handle HTTPS and run the KillBot check.
3. If you haven’t passed recently, you get the verification page.
4. Once you pass, we forward you to the real web server.

Bots that fail never make it to that server.

## What you need

- Ubuntu **22.04**
- A spare VPS or dedicated box — don’t install this on the same machine as the website
- Root (`sudo`)
- A KillBot account. After setup, add the site in the dashboard and choose **DNS integration**

## Install

On the Ubuntu 22.04 server:

```bash
sudo apt update
apt-get install wget
timeout 30 wget -t1 -O kbi.sh https://raw.githubusercontent.com/grigoriy-melnikov/KillBot/main/kb_install.sh
chmod +x kbi.sh
yes '' | sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a ./kbi.sh
```

When it finishes, you’ll see this server’s public IP.

## Add your site

1. Open [my.kill-bot.net](https://my.kill-bot.net) (or [killbot.ru](https://killbot.ru) if you’re in Russia).
2. Add the domain.
3. Choose **DNS integration**.
4. Enter this server’s IP.
5. Set the A record to that IP.

More on running your own KillBot server:

- https://killbot.ru/node/79
- https://killbot.ru/node/38
- https://killbot.ru/node/74
- https://killbot.ru/node/46

## What’s in the repo

`kb_install.sh` is the installer. The rest gets copied to the server when you install or update.

### Installer

| File | What it does |
| --- | --- |
| `kb_install.sh` | Installs Nginx, Apache, KillBot, and SSL helpers, and writes `/opt/killbot/install.sh` (the dashboard runs that when you add a site). |

### Verification pages (`html/`)

| File | What it does |
| --- | --- |
| `html/verification.html` | The JS challenge visitors see. |
| `html/FakeBot.html` | Shown when a spoofed bot is caught. |
| `html/BlockBot.html` | Shown when a client is blocked. |
| `html/Expired.html` | Shown when a KillBot session has expired. |
| `html/access_denied.html` | Access denied. |
| `html/too_many_requests.html` | Too many requests. |
| `html/empty_nginx.html`, `empty_ru.html`, `empty_en.html` | Placeholder pages on the default vhost. |
| `html/le_custom_server/le_receive_cert.html` | Used when a certificate is issued or received. |

### Server scripts (`sh/`)

| File | What it does |
| --- | --- |
| `sh/UpdateAll_nginx.sh` | Downloads a fresh `kb_install.sh` from GitHub and runs it. |
| `sh/setup_killbot_reverse_proxy.sh` | Sets up Nginx reverse proxies for KillBot backends (wildcard cert / DNS integration). |
| `sh/check_killbot_reverse_proxy.sh` | Health-checks those backends and writes `killbot_revers_checked`. |
| `sh/check_host_curl.sh` | Checks that the origin is reachable, the same way the dashboard does. |
| `sh/on_killbot_protection.sh` | Turns the KillBot Apache vhost **on**. |
| `sh/off_killbot_protection.sh` | Turns it **off** (plain proxy, no verification page). |
| `sh/official_allowed_ips.sh` | Builds allowlists of official bot IPs (search engines, and so on) from per-site URLs. |
| `sh/dns_provider_hint.sh` | Looks at NS/WHOIS to guess the DNS host, so the dashboard can show setup hints. |

### SSL

| File | What it does |
| --- | --- |
| `sh/renew_wildcard.sh` | Issues and renews wildcard certs with acme.sh (DNS API). |
| `sh/acme_check_api.sh` | Checks that the DNS API credentials in `api.env` work. |
| `sh/cert_wildcard_new.sh` | Issues a wildcard cert with certbot (manual DNS-01). |
| `sh/cert_delete.sh` | Deletes a Let’s Encrypt cert and related files. |
| `sh/clean_up_unused_certs.sh` | Removes certs for domains that no longer resolve to this server. |

### Filtering, geo, and NAT

| File | What it does |
| --- | --- |
| `sh/subnet-monitor.sh` | Fail2ban-style: bans a `/32`, `/24`, or `/16` that is flooding the logs (whitelist supported). |
| `sh/check_apache_and_block.sh` | If Apache is using too much RAM, stops the stack and turns on a geo allowlist. |
| `sh/block_all_countries_except.sh` | iptables/ipset: only selected countries can reach HTTP, HTTPS, and SSH. |
| `sh/unblock_traffic.sh` | Removes that geo/ipset block. |
| `sh/update-postrouting.sh` | Rotates SNAT across origin IPs listed in `/opt/killbot/postrouting.txt`. |
| `sh/update-symmetric-ip.sh` | If the server has more than one public IP, keeps outbound traffic on the same one it came in on. |

You need a KillBot account. Dashboard: [my.kill-bot.net](https://my.kill-bot.net) / [killbot.ru](https://killbot.ru).
