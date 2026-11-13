#!/usr/bin/env bash
# installer2 — GB limit helper.
# Purpose: GB + Days, whichever comes first, closes the account.
# Record format (one file per user, under /etc/n4vpn/accounts/):
#   GB_LIMIT=10   (GB, integer, per validity period)
#   USED_BYTES=0  (bytes counted by the accounting collector)
#   EXPIRY=2026-11-05 (YYYY-MM-DD, same date as the Linux account expiry)
# Behaviour: if today > EXPIRY, or USED_BYTES >= GB_LIMIT*1024^3,
#   lock the Linux user and kill its sessions.
#   The ShareLink is deliberately NOT deleted (changed 2026-11-13): a
#   closed account keeps its link so the user can still check status /
#   balance — the share page shows Expired / GB limit reached and the VPN
#   itself stays locked server-side. Only a manual delete (Menu / Bot /
#   n4-create-user delete) removes the share, via n4-cleanup <user>.
# Renewal must reset USED_BYTES to 0 and set a new EXPIRY + GB_LIMIT.
set -u
N4_DIR=/etc/n4vpn
ACCOUNTS_DIR=$N4_DIR/accounts
LOG=/var/log/n4vpn/gb-limit.log

log() { mkdir -p /var/log/n4vpn; echo "$(date '+%F %T') $*" >>"$LOG"; }

gb_to_bytes() { echo $(( ${1:-0} * 1024 * 1024 * 1024 )); }

close_user() {
  local u=$1 reason=$2
  log "CLOSE $u reason=$reason"
  usermod -L "$u" 2>/dev/null || true
  pkill -KILL -u "$u" 2>/dev/null || true
  # Share is NOT deleted here (see header): the user keeps checking
  # status/balance on the ShareLink; only manual delete removes it.
}

check_user() {
  local f=$1 u gb used expiry today
  u=$(basename "$f")
  gb=$(awk -F= '/^GB_LIMIT=/{print $2; exit}' "$f" 2>/dev/null || echo 0)
  used=$(awk -F= '/^USED_BYTES=/{print $2; exit}' "$f" 2>/dev/null || echo 0)
  expiry=$(awk -F= '/^EXPIRY=/{print $2; exit}' "$f" 2>/dev/null || echo "")
  today=$(date +%F)
  if [[ -n $expiry && $today > $expiry ]]; then close_user "$u" "expired:$expiry"; return; fi
  if [[ $gb =~ ^[0-9]+$ && $used =~ ^[0-9]+$ && $gb -gt 0 ]]; then
    if (( used >= $(gb_to_bytes "$gb") )); then close_user "$u" "gb-limit:${gb}GB"; fi
  fi
}

main() {
  [[ -d $ACCOUNTS_DIR ]] || exit 0
  for f in "$ACCOUNTS_DIR"/*; do [[ -f $f ]] || continue; check_user "$f"; done
}
main "$@"
