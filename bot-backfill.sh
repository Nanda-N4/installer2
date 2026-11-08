#!/usr/bin/env bash
# n4-bot-backfill - one-time backfill for the Bot-only user list.
# Owner decision 2026-11-08: Menu users must not appear in the Bot.
# Bot-only registry is /etc/n4vpn/bot-users (one username per line).
# This script ONLY ADDS to that registry. It never deletes a user,
# never touches /etc/passwd, accounts, shares or device limits, and
# never removes a name from the registry.
# How it decides (honest limit: old users carry no "created by Bot"
# marker, so 100% automatic detection is impossible):
#   1. AUTO: Bot Auto-Gen pattern only - "n4" + 4 chars that are
#      exactly 3 digits + 1 lowercase letter (e.g. n420h5, n4508m).
#      A Menu user with that exact pattern would be wrongly added;
#      the script prints every auto-added name so the owner can see
#      it and remove it with:
#        sed -i '/^<name>$/d' /etc/n4vpn/bot-users; systemctl restart n4-bot
#   2. PICK: every other existing user is listed with a number and
#      the owner picks the Bot ones by number (space-separated).
#      Nothing is picked = nothing added for those users.
#   3. Re-running is safe (idempotent): names already in the
#      registry are never duplicated.
# Non-interactive use (no tty): only step 1 runs, unless
# BOT_BACKFILL_SELECT="2 3" is set (numbers, same as the prompt).
# Usage: run as root, once per VPS after Update:
#   n4-bot-backfill
set -u
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
REG=/etc/n4vpn/bot-users
mkdir -p /etc/n4vpn
[[ -f $REG ]] || { touch "$REG"; chmod 600 "$REG"; }

is_auto_pattern(){
  local u=$1 rest digits letters i c
  [[ ${#u} -eq 6 ]] || return 1
  [[ $u == n4* ]] || return 1
  rest=${u:2}; digits=0; letters=0
  for ((i=0; i<4; i++)); do
    c=${rest:i:1}
    case $c in
      [0-9]) digits=$((digits+1));;
      [a-z]) letters=$((letters+1));;
      *) return 1;;
    esac
  done
  [[ $digits -eq 3 && $letters -eq 1 ]]
}

in_registry(){
  local u=$1
  grep -qx -- "$u" "$REG" 2>/dev/null
}

add_user(){
  local u=$1
  in_registry "$u" && return 0
  printf '%s\n' "$u" >>"$REG"
}

mapfile -t all < <(awk -F: '$3>=1000 && $1!="nobody" {print $1}' /etc/passwd 2>/dev/null | sort)
remaining=()
auto_added=()
for u in "${all[@]}"; do
  in_registry "$u" && continue
  if is_auto_pattern "$u"; then
    add_user "$u"; auto_added+=("$u")
  else
    remaining+=("$u")
  fi
done

echo "Bot-only backfill: /etc/n4vpn/bot-users"
if ((${#auto_added[@]})); then
  echo "Auto-added (Bot Auto-Gen pattern n4+3 digits+1 letter):"
  printf '  %s\n' "${auto_added[@]}"
else
  echo "Auto-added: none (no new Auto-Gen pattern users)."
fi

if ((${#remaining[@]})); then
  echo
  echo "Remaining users (not in Bot list yet). Pick the Bot ones:"
  i=1; for u in "${remaining[@]}"; do echo "  $i) $u"; i=$((i+1)); done
  sel=""
  if [[ -t 0 ]]; then
    read -r -p 'Enter numbers of Bot users (space-separated, empty = none): ' sel || sel=""
  elif [[ -n ${BOT_BACKFILL_SELECT:-} ]]; then
    sel="$BOT_BACKFILL_SELECT"
  else
    echo "(Not a terminal: skipping the pick step. Re-run interactively to pick, or set BOT_BACKFILL_SELECT.)"
  fi
  picked=()
  for n in $sel; do
    [[ $n =~ ^[0-9]+$ ]] || { echo "  Ignored invalid entry: $n"; continue; }
    (( n>=1 && n<=${#remaining[@]} )) || { echo "  Ignored out of range: $n"; continue; }
    u=${remaining[$((n-1))]}
    add_user "$u"; picked+=("$u")
  done
  if ((${#picked[@]})); then
    echo "Picked and added:"
    printf '  %s\n' "${picked[@]}"
  else
    echo "Picked: none."
  fi
else
  echo "Remaining users: none."
fi

sort -u -o "$REG" "$REG" 2>/dev/null || true
chmod 600 "$REG" 2>/dev/null || true
echo
echo "Bot list now ($(wc -l <"$REG" | tr -d ' ') users):"
cat "$REG"
echo "VPN users were NOT changed (no user created/deleted, no password/expiry/GB changed)."
if [[ -f /etc/systemd/system/n4-bot.service ]]; then
  if systemctl restart n4-bot 2>/dev/null; then
    echo "Bot restarted - new list is live."
  else
    echo "Bot restart failed - run: systemctl restart n4-bot"
  fi
else
  echo "Bot service not found - set up the Bot first (Menu > [8] TG BOT), then restart it."
fi
