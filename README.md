# KillBot DNS Verification page

Install a self-hosted KillBot DNS Verification page on a clean **Ubuntu 22.04** server.

KillBot runs as a reverse proxy in front of your website. All incoming traffic reaches the KillBot server first. New visitors complete a lightweight JavaScript verification, and only verified traffic is forwarded to your origin server.

The verification page is designed specifically to detect **human-like behavioral bots**—automation that uses a real browser and closely imitates normal users. Because a client must also execute JavaScript before reaching the protected website, the same verification page blocks basic HTTP bots, vulnerability scanners, scrapers, and many application-layer (L7) DDoS tools that cannot run the challenge.

This repository contains the installer, verification pages, and server-side maintenance scripts used by a self-hosted KillBot server.

## When to use it

Use the DNS Verification page when you need to stop unwanted traffic **before it reaches or downloads content from your website**, for example to:

- block human-like bots and browser automation;
- stop simple HTTP bots, scanners, and scrapers;
- reduce spam and automated form submissions;
- protect prices, contact details, and original content from scraping;
- keep bot traffic out of analytics and advertising funnels;
- absorb common L7 floods before they reach the origin server.

This is different from KillBot's JavaScript-only integration. A script embedded in a website can identify and analyze a visitor only after the HTML has already been served. The DNS Verification page sits in front of the website and can deny access before the origin returns any content.

> KillBot provides practical protection against the common L7 attacks that often overwhelm regular websites. It is not a replacement for carrier-grade network protection against very large volumetric DDoS attacks.

## How it works

```text
Visitor or bot
      |
      v
Your domain -> KillBot DNS Verification page -> Origin website
                   |
                   +-- JavaScript verification
                   +-- Behavioral bot detection
                   +-- HTTP and subnet rate controls
```

1. The domain's DNS record points to the KillBot server instead of directly to the origin.
2. Nginx accepts the public HTTP/HTTPS connection and passes it to the local KillBot stack.
3. A visitor who has not been verified recently receives the KillBot JavaScript verification page.
4. KillBot analyzes the browser environment and behavior. Suspicious visits can be blocked, challenged, or trapped in a loop, depending on the project settings.
5. Verified visitors are reverse-proxied to the real website. Failed clients never reach the origin.

For most legitimate visitors, verification is automatic. A CAPTCHA is shown only when the configured rules require it.

## Requirements

- A **clean Ubuntu 22.04** server without a hosting control panel
- A separate VPS or dedicated server; do not install KillBot on the origin web server
- At least **2 vCPU, 2 GB RAM, and 20 GB of disk space**
- Root or `sudo` access
- One public IPv4 address
- A [KillBot account](https://my.kill-bot.net/)

Ubuntu 24.04 is not currently supported by this installer.

## Install

Run these commands on the clean Ubuntu 22.04 server:

```bash
sudo apt update
sudo apt-get install -y wget
wget -O kbi.sh https://raw.githubusercontent.com/grigoriy-melnikov/KillBot/main/kb_install.sh
chmod +x kbi.sh
yes '' | sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a ./kbi.sh
```

The installer deploys Nginx, Apache, the KillBot verification pages, SSL tooling, firewall helpers, and scheduled maintenance jobs. Runtime files are stored under `/opt/killbot`.

Installation may end with `Failed to stop postfix.service: Unit postfix.service not loaded.` This is harmless: KillBot disables the mail service, and a clean server may not have Postfix installed.

## Connect a website

1. Sign in at [my.kill-bot.net](https://my.kill-bot.net/) or [killbot.ru](https://killbot.ru/) if you are in Russia.
2. Add your domain and select **DNS integration / KillBot DNS Verification page**.
3. Enter the origin server IP—the server where the website itself is hosted.
4. Select your self-hosted KillBot server and enter its public IP.
5. Save the project settings and follow the displayed SSL and DNS instructions.
6. Change the domain's `A` record so that it points to the KillBot server.

Remove conflicting `A` records. KillBot currently uses IPv4, so remove `AAAA` records for hostnames protected by the verification page unless your particular configuration explicitly supports them.

If the website receives callbacks that do not run JavaScript—payment notifications, webhooks, external APIs, monitoring systems, or similar services—allowlist their source IP addresses or User-Agents in the KillBot project settings.

Configuration for connected domains is generated from the KillBot dashboard. Do not make permanent edits directly in generated Nginx or Apache virtual-host files: saving or reloading the project can overwrite them.

## Server layout

| Path | Purpose |
| --- | --- |
| `/opt/killbot` | KillBot runtime, settings, scripts, pages, and SSL files |
| `/etc/nginx/sites-enabled/<domain>.conf` | Public-facing Nginx virtual host |
| `/etc/apache2/sites-enabled/<domain>-killbot.conf` | KillBot verification and origin-proxy configuration |
| `/opt/killbot/ssl/<domain>/` | Certificate and private-key files for a domain |
| `/etc/cron.d/killbot-cleanup` | Scheduled maintenance, monitoring, and health checks |
| `/var/log/nginx/access.log` | Default traffic source used by the subnet monitor |

## Update KillBot

```bash
sudo /opt/killbot/UpdateAll.sh
```

After a major update, open the project in the KillBot dashboard and use **Reload DNS** so its generated configuration is refreshed.

## Built-in traffic protection

The self-hosted DNS Verification page adds two server-side layers in addition to browser verification:

- **Subnet monitoring:** `subnet-monitor.sh` analyzes recent access-log traffic and can temporarily block abusive individual IPs, `/24` networks, or `/16` networks with iptables. Thresholds, block duration, mode, and log paths are configurable; a whitelist is supported.
- **Nginx rate controls:** generated Nginx configuration can limit the total request rate and requests to a single URL. This helps when a distributed botnet attacks one expensive endpoint from many IP addresses.

Common subnet-monitor commands:

```bash
sudo /opt/killbot/f2b/subnet-monitor.sh show
sudo /opt/killbot/f2b/subnet-monitor.sh test
sudo /opt/killbot/f2b/subnet-monitor.sh run
sudo /opt/killbot/f2b/subnet-monitor.sh clear
```

- `show` lists current KillBot firewall blocks.
- `test` reports request counts without adding blocks.
- `run` immediately analyzes the configured logs.
- `clear` removes blocks created by the monitor.

The installed configuration and whitelist are stored alongside the script under `/opt/killbot/f2b/`. The monitor normally runs once per minute from `/etc/cron.d/killbot-cleanup`.

## Certificates and multiple servers

KillBot supports regular and wildcard certificates. A wildcard certificate is required when the protected configuration uses KillBot proxy subdomains such as `r1.example.com`, or when third-level subdomains also need protection.

For higher availability, a domain can be connected to more than one KillBot server. Follow the dashboard instructions carefully because the required `A`, wildcard, and `_acme-challenge` records depend on the selected certificate and server configuration.

## Repository contents

### Installer

| File | Purpose |
| --- | --- |
| `kb_install.sh` | Validates the host, installs the complete KillBot stack and dependencies, creates runtime configuration under `/opt/killbot`, and installs maintenance jobs. It is also used to refresh an existing installation. |

### Verification pages (`html/`)

| File | Purpose |
| --- | --- |
| `html/verification.html` | Main JavaScript verification page shown before access to a protected site. |
| `html/FakeBot.html` | Response page for a client impersonating an allowlisted or official bot. |
| `html/BlockBot.html` | Response page for a blocked client. |
| `html/Expired.html` | Response shown when a KillBot session or permission has expired. |
| `html/access_denied.html` | Generic access-denied response. |
| `html/too_many_requests.html` | Rate-limit response page. |
| `html/empty_nginx.html` | Empty/default response used by Nginx. |
| `html/empty_ru.html` | Russian placeholder response. |
| `html/empty_en.html` | English placeholder response. |
| `html/le_custom_server/le_receive_cert.html` | Page used by the custom-server certificate workflow. |

### Core and proxy management (`sh/`)

| File | Purpose |
| --- | --- |
| `sh/UpdateAll_nginx.sh` | Downloads the current installer and refreshes the installed server components. |
| `sh/ubuntu_check.sh` | Verifies Ubuntu 22.04 and checks for incompatible hosting panels or pre-existing server stacks. |
| `sh/setup_killbot_reverse_proxy.sh` | Creates per-site Nginx reverse proxies for KillBot backend domains when wildcard DNS and SSL are available. |
| `sh/check_killbot_reverse_proxy.sh` | Runs recurring DNS and HTTP health checks for KillBot proxy backends and removes failed routes from the active list. |
| `sh/check_host_curl.sh` | Tests origin reachability with the requested source IP, host, port, and protocol. |
| `sh/on_killbot_protection.sh` | Enables KillBot verification for installed virtual hosts. |
| `sh/off_killbot_protection.sh` | Switches installed virtual hosts to direct proxy mode without the verification page. |
| `sh/official_allowed_ips.sh` | Downloads and builds cached IP allowlists for verified search engines and other official services. |
| `sh/dns_provider_hint.sh` | Detects the likely DNS provider from nameserver and WHOIS data so the dashboard can display relevant setup instructions. |

### SSL management (`sh/`)

| File | Purpose |
| --- | --- |
| `sh/renew_wildcard.sh` | Issues or renews wildcard certificates through `acme.sh` and a supported DNS provider API. |
| `sh/acme_check_api.sh` | Validates DNS API credentials and detects the matching `acme.sh` DNS provider hook. |
| `sh/cert_wildcard_new.sh` | Starts manual DNS-01 wildcard certificate issuance with Certbot. |
| `sh/cert_delete.sh` | Removes a Let's Encrypt certificate and, unless disabled by an argument, its local KillBot SSL files. |
| `sh/clean_up_unused_certs.sh` | Removes certificates that are no longer used by local virtual hosts or no longer point to the server. |

### DDoS controls, geo filtering, and network routing (`sh/`)

| File | Purpose |
| --- | --- |
| `sh/subnet-monitor.sh` | Analyzes access logs and temporarily blocks abusive IPs, `/24` networks, or `/16` networks; supports configurable thresholds and whitelists. |
| `sh/check_apache_and_block.sh` | Watches memory usage and can stop the web stack and activate emergency country filtering when the configured limit is exceeded. |
| `sh/block_all_countries_except.sh` | Builds ipset/iptables rules that allow only selected countries to reach configured web and administration ports. |
| `sh/unblock_traffic.sh` | Removes the emergency geo/ipset rules created by the blocking scripts. |
| `sh/update-postrouting.sh` | Maintains SNAT rotation across origin IPs listed in `/opt/killbot/postrouting.txt`. |
| `sh/update-symmetric-ip.sh` | Keeps reply traffic on the same public IP that accepted the connection when the KillBot server has multiple addresses. |

## Operational notes

- One KillBot server can protect multiple websites.
- The origin IP must remain reachable from the KillBot server.
- Search-engine crawlers can be allowlisted and verified separately from clients that merely spoof their User-Agent.
- Keep webhook and payment-provider allowlists current.
- Review thresholds before enabling aggressive subnet or country blocking on a high-traffic website.
- Back up custom verification-page changes before updating the server.

## Documentation

- [Deploying KillBot on your own server](https://my.kill-bot.net/node/46)
- [Self-hosted server configuration and maintenance](https://my.kill-bot.net/node/79)
- [DNS Verification page vs. JavaScript integration](https://my.kill-bot.net/node/38)
- [Using multiple KillBot servers](https://my.kill-bot.net/node/74)

Dashboard: [my.kill-bot.net](https://my.kill-bot.net/) · Russia: [killbot.ru](https://killbot.ru/)
