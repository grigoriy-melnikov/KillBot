#!/bin/bash
set -e

LOCK_FILE="/var/run/apache_block.lock"
LOG_FILE="/var/log/apache_block.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE" >&2
}

log "=== Starting unblock procedure ==="

if [ -f "$LOCK_FILE" ]; then
  log "Lock file found: protection was active."
else
  log "Lock file not found: protection is inactive (or already lifted)."
fi

# Which ipsets may have been used
SET_CANDIDATES=("ru-whitelist" "country-whitelist" "whitelist")

# Find an existing set (first in the list)
FOUND_SET=""
for s in "${SET_CANDIDATES[@]}"; do
  if sudo ipset list "$s" >/dev/null 2>&1; then
    FOUND_SET="$s"
    break
  fi
done

if [ -n "$FOUND_SET" ]; then
  log "Found ipset: $FOUND_SET"
else
  log "No ipset from the list (${SET_CANDIDATES[*]}) was found. Will only remove DROP/ACCEPT by ports if present."
fi

log "Removing iptables rules related to geo-blocking..."

# Collect rule numbers to delete (in reverse order!)
# 1) ACCEPT with match-set (if a set was found)
# 2) DROP on the same ports (80/443/22 if present) — we only remove multiport dports with target DROP
RULE_NUMBERS=""

if [ -n "$FOUND_SET" ]; then
  RULE_NUMBERS="$(sudo iptables -L INPUT -n --line-numbers \
    | awk -v setname="$FOUND_SET" '
      /match-set/ && $0 ~ setname && $0 ~ /multiport dports/ {print $1}
    ' | sort -rn)"
fi

# DROP multiport dports (do not touch other DROP rules by subnet!)
DROP_RULES="$(sudo iptables -L INPUT -n --line-numbers \
  | awk '
    $0 ~ /multiport dports/ && $2=="DROP" {print $1}
  ' | sort -rn)"

# Merge (ACCEPT + DROP), keep unique numbers, sort descending
ALL_NUMS="$(printf "%s\n%s\n" "$RULE_NUMBERS" "$DROP_RULES" | awk 'NF' | sort -rn | uniq)"

if [ -z "$ALL_NUMS" ]; then
  log "No matching rules (ACCEPT match-set / DROP multiport dports) found."
else
  for num in $ALL_NUMS; do
    log "Removing INPUT rule #$num"
    sudo iptables -D INPUT "$num" || true
  done
fi

# Destroy the ipset (if found)
if [ -n "$FOUND_SET" ]; then
  log "Destroying ipset $FOUND_SET..."
  sudo ipset destroy "$FOUND_SET" 2>/dev/null || true
fi

# Remove the lock file
if [ -f "$LOCK_FILE" ]; then
  rm -f "$LOCK_FILE"
  log "Lock file removed."
fi

log "Result: first 30 INPUT rules:"
sudo iptables -L INPUT -n -v --line-numbers | head -n 30 | tee -a "$LOG_FILE" >/dev/null

log "=== Unblock complete ==="

