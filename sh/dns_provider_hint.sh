# shellcheck shell=bash
# DNS panel hint from the domain NS (dig + whois). Source: source "$(dirname "$0")/dns_provider_hint.sh"
#
#   dns_registrar_hint_ru DOMAIN   — user-facing text (EN, kept for compatibility)
#   dns_registrar_hint_en DOMAIN   — text for API/logs (EN)

_dns_hint_normalize_ns() {
    local h="${1,,}"
    h="${h%.}"
    h="${h%% *}"
    [[ "$h" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || return 1
    printf '%s\n' "$h"
}

_dns_hint_nameservers_from_dig() {
    local domain="$1" line
    command -v dig >/dev/null 2>&1 || return 0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _dns_hint_normalize_ns "$line" || continue
    done < <(dig +short NS "${domain}" 2>/dev/null | sort -u)
}

_dns_hint_nameservers_from_whois() {
    local domain="$1" whois_out="" whois_host line host
    command -v whois >/dev/null 2>&1 || return 0

    if [[ "$domain" =~ \.(ru|su|рф)$ ]]; then
        whois_out="$(whois -h whois.nic.ru "${domain}" 2>/dev/null || true)"
    fi
    if [[ -z "$whois_out" ]] || echo "$whois_out" | grep -qiE 'not found|no match|no entries found'; then
        whois_out="$(whois "${domain}" 2>/dev/null || true)"
    fi
    [[ -n "$whois_out" ]] || return 0

    while IFS= read -r line; do
        if [[ "$line" =~ ^[Nn](ame[[:space:]]+[Ss]erver|server)[[:space:]]*[:.]?[[:space:]]*(.+)$ ]]; then
            host="${BASH_REMATCH[2]}"
            _dns_hint_normalize_ns "$host" || continue
        fi
    done <<< "$whois_out"
}

_dns_hint_collect_nameservers() {
    local domain="$1"
    DNS_HINT_NS=()
    local ns
    while IFS= read -r ns; do
        [[ -n "$ns" ]] && DNS_HINT_NS+=("$ns")
    done < <(_dns_hint_nameservers_from_dig "$domain")
    if [[ ${#DNS_HINT_NS[@]} -eq 0 ]]; then
        while IFS= read -r ns; do
            [[ -n "$ns" ]] && DNS_HINT_NS+=("$ns")
        done < <(_dns_hint_nameservers_from_whois "$domain")
    fi
}

_dns_hint_guess_provider() {
    local joined="${1,,}"
  [[ -n "$joined" ]] || { DNS_HINT_PROVIDER=""; return 0; }

    case "$joined" in
        *cloudflare.com*) DNS_HINT_PROVIDER="Cloudflare" ;;
        *reg.ru*) DNS_HINT_PROVIDER="REG.RU" ;;
        *nic.ru*) DNS_HINT_PROVIDER="RU-CENTER (NIC.RU)" ;;
        *ru-center.ru*) DNS_HINT_PROVIDER="RU-CENTER" ;;
        *beget.com*|*beget.pro*) DNS_HINT_PROVIDER="Beget" ;;
        *timeweb.ru*) DNS_HINT_PROVIDER="Timeweb" ;;
        *yandex.net*|*yandexcloud.net*) DNS_HINT_PROVIDER="Yandex" ;;
        *selectel.org*|*selectel.ru*) DNS_HINT_PROVIDER="Selectel" ;;
        *digitalocean.com*) DNS_HINT_PROVIDER="DigitalOcean" ;;
        *awsdns*) DNS_HINT_PROVIDER="Amazon Route 53" ;;
        *domaincontrol.com*) DNS_HINT_PROVIDER="GoDaddy" ;;
        *registrar-servers.com*) DNS_HINT_PROVIDER="Namecheap" ;;
        *hetzner.de*) DNS_HINT_PROVIDER="Hetzner" ;;
        *hostinger*) DNS_HINT_PROVIDER="Hostinger" ;;
        *wixdns.net*) DNS_HINT_PROVIDER="Wix" ;;
        *vercel-dns.com*) DNS_HINT_PROVIDER="Vercel" ;;
        *) DNS_HINT_PROVIDER="" ;;
    esac
}

_dns_hint_format_ns_list() {
    local IFS=', '
    echo "${DNS_HINT_NS[*]}"
}

dns_registrar_hint_ru() {
    local domain="$1" ns_list
    _dns_hint_collect_nameservers "$domain"
    _dns_hint_guess_provider "$(printf '%s\n' "${DNS_HINT_NS[@]}")"

    ns_list="$(_dns_hint_format_ns_list)"
    if [[ -n "${DNS_HINT_PROVIDER}" && -n "$ns_list" ]]; then
        printf 'Add the record in the DNS panel of provider "%s" (NS of domain %s: %s)' \
            "${DNS_HINT_PROVIDER}" "$domain" "$ns_list"
    elif [[ -n "$ns_list" ]]; then
        printf 'Add the record in the DNS panel of the host that serves NS of domain %s (%s)' \
            "$domain" "$ns_list"
    else
        printf 'Add the record in the DNS panel where domain %s NS are configured (see WHOIS or the registrar account)' \
            "$domain"
    fi
}

dns_registrar_hint_en() {
    local domain="$1" ns_list
    _dns_hint_collect_nameservers "$domain"
    _dns_hint_guess_provider "$(printf '%s\n' "${DNS_HINT_NS[@]}")"

    ns_list="$(_dns_hint_format_ns_list)"
    if [[ -n "${DNS_HINT_PROVIDER}" && -n "$ns_list" ]]; then
        printf 'Add the record in the DNS control panel of %s (nameservers for %s: %s).' \
            "${DNS_HINT_PROVIDER}" "$domain" "$ns_list"
    elif [[ -n "$ns_list" ]]; then
        printf 'Add the record in the DNS control panel of the host that serves nameservers for %s (%s).' \
            "$domain" "$ns_list"
    else
        printf 'Add the record in the DNS control panel where nameservers (NS) for %s are managed (check WHOIS or your registrar account).' \
            "$domain"
    fi
}
