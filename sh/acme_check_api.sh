#!/usr/bin/env bash
# Universal DNS API auth check via acme.sh (auto provider detection + cleanup + timeout)

ACME_HOME="/root/.acme.sh"
ACME_DNSAPI_DIR="$ACME_HOME/dnsapi"
TIMEOUT=15   # seconds

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /opt/killbot/certs/domain/api.env"
  exit 1
fi

# ────────────────────────────────────────────────
# Internal timeout guard — kill script if >15s
# ────────────────────────────────────────────────
(
  sleep "$TIMEOUT"
  echo "⚠️  Script timed out after ${TIMEOUT}s — aborting" >&2
  pkill -P $$ 2>/dev/null || kill $$ 2>/dev/null
) &
TIMEOUT_PID=$!

# ────────────────────────────────────────────────
# Core helpers
# ────────────────────────────────────────────────
_post() { curl -s -X POST -H "Content-Type: application/x-www-form-urlencoded" -d "$1" "$2"; }
_get() { curl -s "$1"; }
_contains() { echo "$1" | grep -q "$2"; }
_idn() { echo "$1"; }
_readaccountconf_mutable() { :; }
_saveaccountconf_mutable() { :; }
_readaccountconf() { :; }
_info() { echo "ℹ️  $*"; }
_err() { echo "❌ $*" >&2; }
_debug() { echo "🐞 $*" >&2; }
_debug2() { echo "🐞 $*" >&2; }
_math() { echo "$(($@))"; }
_clearaccountconf_mutable() { :; }
_clearaccountconf() { :; }
_secure_debug() { :; }
_h2() { echo "$@"; }
_egrep_o() { grep -Eo "$@"; }
_head_n() { head -n "$1"; }


API_ENV="$1"
DOMAIN=$(basename "$(dirname "$API_ENV")")
PROVIDER_FILE="$(dirname "$API_ENV")/provider"

if [[ ! -f "$API_ENV" ]]; then
  echo "❌ File $API_ENV not found"
  kill "$TIMEOUT_PID" 2>/dev/null
  exit 2
fi

if [[ ! -f "$PROVIDER_FILE" ]]; then
  echo "❌ Provider file not found: $PROVIDER_FILE"
  kill "$TIMEOUT_PID" 2>/dev/null
  exit 3
fi

DNS_PROVIDER=$(tr -d '\r\n' < "$PROVIDER_FILE")

# ────────────────────────────────────────────────
# Map provider → hook
# ────────────────────────────────────────────────
get_dns_hook_by_provider() {
    local provider="$1"
    case "$provider" in
        "regru") echo "dns_regru" ;;
        "cloudflare") echo "dns_cf" ;;
        "godaddy") echo "dns_gd" ;;
        "namecheap") echo "dns_namecheap" ;;
        "digitalocean") echo "dns_do" ;;
        "aws"|"route53") echo "dns_aws" ;;
        "beget") echo "dns_beget" ;;
        "timeweb") echo "dns_timeweb" ;;
        "sprinthost") echo "dns_sprinthost" ;;
        "spaceweb") echo "dns_spaceweb" ;;
        "fornex") echo "dns_fornex" ;;
        "adminvps") echo "dns_adminvps" ;;
        *) echo "dns_$provider" ;;
    esac
}

DNS_HOOK=$(get_dns_hook_by_provider "$DNS_PROVIDER")
HOOK_PATH="$ACME_DNSAPI_DIR/${DNS_HOOK}.sh"

if [[ ! -f "$HOOK_PATH" ]]; then
  echo "❌ DNS hook not found: $HOOK_PATH"
  kill "$TIMEOUT_PID" 2>/dev/null
  exit 4
fi

echo "▶ Testing DNS API auth for: $DOMAIN"
echo "▶ Provider: $DNS_PROVIDER"
echo "▶ Hook: $HOOK_PATH"

# ---- Minimal stubs for acme.sh internals ----
_info()  { echo "ℹ️  $*"; }
_err()   { echo "❌ $*" >&2; }
_debug() { echo "🐞 $*" >&2; }
_saveaccountconf_mutable() { :; }
_readaccountconf_mutable() { :; }
_secure_debug() { :; }
_h2() { echo "$@"; }

# ---- Load environment (universal way) ----
if grep -q '^export' "$API_ENV"; then
  eval "$(cat "$API_ENV")"
else
  set -a
  source "$API_ENV"
  set +a
fi

# ---- Override _post/_get only for Cloudflare ----
if [[ "$DNS_PROVIDER" == "cloudflare" ]]; then
  _post() {
    local data="$1" url="$2" method="${3:-}"
    # Auto-detect DELETE when the body is empty and the URL looks like a delete
    if [[ -z "$method" ]]; then
      if [[ "$url" =~ /dns_records/ ]] && [[ -z "$data" ]]; then
        method="DELETE"
      else
        method="POST"
      fi
    fi

    curl -sS -X "$method" \
      -H "${_H1:-Content-Type: application/json}" \
      ${_H2:+-H "$_H2"} \
      ${_H3:+-H "$_H3"} \
      ${data:+-d "$data"} \
      "$url"
  }

  _get() {
    local url="$1"
    curl -sS -X GET \
      -H "${_H1:-Content-Type: application/json}" \
      ${_H2:+-H "$_H2"} \
      ${_H3:+-H "$_H3"} \
      "$url"
  }
fi

# ---- Load hook ----
source "$HOOK_PATH"

# ---- Special handling for Cloudflare token ----
if [[ "$DNS_PROVIDER" == "cloudflare" && -n "$CF_Token" ]]; then
  _saveaccountconf_mutable CF_Token "$CF_Token"
  _saveaccountconf_mutable CF_Account_ID "$CF_Account_ID"
fi

FULLDOMAIN="_acme-challenge.$DOMAIN"
TXTVAL="KillBotTest$(date +%s)"

echo "▶ Calling ${DNS_HOOK}_add '$FULLDOMAIN' '$TXTVAL' ..."
echo "──────────────────────────────────────────────"

RAW_OUTPUT=$(
  { "${DNS_HOOK}_add" "$FULLDOMAIN" "$TXTVAL"; } 2>&1
)
EXIT_CODE=$?

echo "🌐 Provider raw output:"
echo "$RAW_OUTPUT"
echo "──────────────────────────────────────────────"

# ---- Analyze result ----
if [[ $EXIT_CODE -ne 0 ]]; then
  echo "❌ DNS API access failed — hook exited with code $EXIT_CODE"
  kill "$TIMEOUT_PID" 2>/dev/null
  exit 5
fi

if echo "$RAW_OUTPUT" | grep -qiE "(Failed to add TXT record|not authorized|forbidden|invalid credentials|error adding TXT)"; then
  echo "❌ DNS API access failed — provider rejected credentials"
  kill "$TIMEOUT_PID" 2>/dev/null
  exit 6
fi

echo "✅ DNS API access successful — credentials are valid"

# ---- Cleanup ----
if declare -F "${DNS_HOOK}_rm" >/dev/null 2>&1; then
  echo "▶ Cleaning up test TXT record..."
  CLEAN_OUTPUT=$(
    { "${DNS_HOOK}_rm" "$FULLDOMAIN" "$TXTVAL"; } 2>&1
  )
  CLEAN_CODE=$?
  echo "🌐 Cleanup output:"
  echo "$CLEAN_OUTPUT"
  if [[ $CLEAN_CODE -eq 0 ]]; then
    echo "🧹 Test TXT record removed OK"
  else
    echo "⚠️  Cleanup failed (exit $CLEAN_CODE) — record may remain"
  fi
else
  echo "⚠️  Cleanup not supported — ${DNS_HOOK}_rm not implemented"
fi

# cancel timeout watcher
kill "$TIMEOUT_PID" 2>/dev/null
