#!/usr/bin/env bash
# n4-create-user.sh - NON-INTERACTIVE unified create/renew/delete.
# Called by menu.sh (future) and by bot.py (Telegram bot, fast version).
# Usage:
#   n4-create-user.sh create <user> <password> <days> <gb> [limit]
#   n4-create-user.sh renew  <user> <days> <gb>
#   n4-create-user.sh delete <user>
# create does, in order, exactly what menu create does:
#   Linux user + expiry, session limit file, GB accounts record,
#   V2Ray add (link), share link. It never prints the password.
# Exit codes: 0 ok, 2 bad args, 3 already exists / not found, 4 create failed.
set -u
N4=/etc/n4vpn; CONF=$N4/n4.conf; DEV=$N4/device-limits; SHARES=$N4/shares
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 2; }
load(){ VPN_SSH_PORT=109; WS_PORTS='80'; HYBRID_PORT=443; HOST_DOMAIN=''; SHARE_PORT=8880; DEVICE_LIMIT_DEFAULT=1; SLOWDNS_ENABLED=0; NS_DOMAIN=''; [[ -f $CONF ]] && source "$CONF" || true; }
sync_limits(){ local f=/etc/security/limits.d/99-n4vpn-users.conf q u l; : >"$f"; for q in "$DEV"/*; do [[ -f $q ]] || continue; u=$(basename "$q"); l=$(cat "$q" 2>/dev/null || echo 0); [[ $l =~ ^[0-9]+$ ]] || continue; ((l>0)) && echo "$u hard maxlogins $l" >>"$f"; done; }
valid_user(){ [[ ${1:-} =~ ^[a-z_][a-z0-9_-]{1,31}$ ]]; }
valid_num(){ [[ ${1:-} =~ ^[0-9]+$ ]]; }

do_create(){
  local u=$1 p=$2 d=$3 gb=$4 l=${5:-$DEVICE_LIMIT_DEFAULT}
  valid_user "$u" || { echo 'Invalid username.' >&2; exit 2; }
  [[ -n $p ]] || { echo 'Password required.' >&2; exit 2; }
  valid_num "$d" && valid_num "$gb" && valid_num "$l" || { echo 'Invalid number.' >&2; exit 2; }
  id "$u" &>/dev/null && { echo 'Account already exists.' >&2; exit 3; }
  local exp; exp=$(date -d "+$d days" +%F)
  useradd -M -s /bin/false -e "$exp" -p "$(openssl passwd -6 "$p")" "$u" || { echo 'Create failed.' >&2; exit 4; }
  mkdir -p "$DEV" "$SHARES" "$N4/accounts"
  echo "$l" >"$DEV/$u"; sync_limits
  printf 'GB_LIMIT=%s\nUSED_BYTES=0\nEXPIRY=%s\n' "$gb" "$exp" >"$N4/accounts/$u"; chmod 600 "$N4/accounts/$u"
  local token epoch file link; token=$(openssl rand -hex 24); epoch=$(date -d "$exp 23:59:59" +%s); file="$SHARES/$token.json"
  python3 - "$file" "$u" "$p" "$exp" "$epoch" "$HOST_DOMAIN" "$VPN_SSH_PORT" "$WS_PORTS" "$HYBRID_PORT" '' "${NS_DOMAIN:-}" <<'PY'
import json,sys
p,u,pw,ed,ee,h,ssh,ws,hy,db,ns=sys.argv[1:]
d={'username':u,'password':pw,'expires_date':ed,'expires_epoch':int(ee),'host':h,'ssh_port':ssh,'ws_ports':ws,'hybrid_port':hy,'dropbear_ports':db,'slowdns_ns':ns}
with open(p,'w',encoding='utf-8') as f: json.dump(d,f,ensure_ascii=False)
PY
  if id -u n4share >/dev/null 2>&1; then chown n4share:n4share "$file" 2>/dev/null || true; chmod 640 "$file" 2>/dev/null || true; fi
  link="http://$HOST_DOMAIN:$SHARE_PORT/s/$token"
  echo "USER:$u"; echo "EXPIRY:$exp"; echo "GB:$gb"; echo "LIMIT:$l"
  echo "SSH:$HOST_DOMAIN:$VPN_SSH_PORT"; echo "HYBRID:$HOST_DOMAIN:$HYBRID_PORT"; echo "WS:$WS_PORTS"
  echo "SHARE:$link"
}
do_renew(){
  local u=$1 d=$2 gb=$3
  valid_user "$u" || { echo 'Invalid username.' >&2; exit 2; }
  valid_num "$d" && valid_num "$gb" || { echo 'Invalid number.' >&2; exit 2; }
  id "$u" &>/dev/null || { echo 'Not found.' >&2; exit 3; }
  local cur base new; cur=$(chage -l "$u" | awk -F': ' '/Account expires/{print $2}'); base=$(date +%F)
  [[ $cur != never && -n $cur ]] && base=$(date -d "$cur" +%F 2>/dev/null || date +%F)
  [[ $(date -d "$base" +%s) -lt $(date +%s) ]] && base=$(date +%F)
  new=$(date -d "$base +$d days" +%F); chage -E "$new" "$u"
  mkdir -p "$N4/accounts"; printf 'GB_LIMIT=%s\nUSED_BYTES=0\nEXPIRY=%s\n' "$gb" "$new" >"$N4/accounts/$u"; chmod 600 "$N4/accounts/$u"
  echo "USER:$u"; echo "EXPIRY:$new"; echo "GB:$gb"
}
do_delete(){
  local u=$1; valid_user "$u" || { echo 'Invalid username.' >&2; exit 2; }
  id "$u" &>/dev/null || { echo 'Not found.' >&2; exit 3; }
  pkill -KILL -u "$u" 2>/dev/null || true; userdel -f "$u"
  rm -f "$DEV/$u" "$N4/accounts/$u"; sync_limits
  [[ -x /usr/local/sbin/n4-cleanup ]] && /usr/local/sbin/n4-cleanup "$u" >/dev/null 2>&1 || true
  echo "DELETED:$u"
}
load
case ${1:-} in
  create) do_create "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" ;;
  renew)  do_renew "${2:-}" "${3:-}" "${4:-}" ;;
  delete) do_delete "${2:-}" ;;
  *) echo "Usage: $0 {create <user> <pass> <days> <gb> [limit]|renew <user> <days> <gb>|delete <user>}" >&2; exit 2 ;;
esac
