#!/usr/bin/env bash
set -u
N4=/etc/n4vpn; CONF=$N4/n4.conf; DEV=$N4/device-limits; SHARES=$N4/shares
C1='\033[38;5;51m'; C2='\033[38;5;48m'; C3='\033[38;5;220m'; C4='\033[38;5;231m'; C5='\033[38;5;244m'; CR='\033[38;5;196m'; CB='\033[38;5;75m'; CP='\033[38;5;141m'; B='\033[1m'; N='\033[0m'
[[ $EUID -eq 0 ]] || { echo 'Run as root'; exit 1; }
mkdir -p "$DEV" "$SHARES" /var/log/n4vpn

load(){
 VPN_SSH_PORT=109; WS_PORTS='80'; DROPBEAR_PORTS=''; HYBRID_PORT=443; DROPBEAR_INTERNAL_PORT=1443
 DEVICE_LIMIT_DEFAULT=1; WS_MAX_CLIENTS=2048; WS_IDLE_TIMEOUT=180; HOST_DOMAIN="$(hostname -I 2>/dev/null|awk '{print $1}')"; PUBLIC_IPV4=''; SLOWDNS_ENABLED=0; NS_DOMAIN=''; SHARE_PORT=8880
 AUTO_REBOOT=1; HEALTH_FAIL_THRESHOLD=5; HEALTH_REBOOT_COOLDOWN=21600
 [[ -f $CONF ]] && source "$CONF" || true
 [[ -z ${PUBLIC_IPV4:-} ]] && PUBLIC_IPV4=$(hostname -I 2>/dev/null|awk '{print $1}')
}
save(){ cat >"$CONF" <<EOF
VPN_SSH_PORT=$VPN_SSH_PORT
WS_PORTS="$WS_PORTS"
DROPBEAR_PORTS="$DROPBEAR_PORTS"
HYBRID_PORT=$HYBRID_PORT
DROPBEAR_INTERNAL_PORT=$DROPBEAR_INTERNAL_PORT
DEVICE_LIMIT_DEFAULT=$DEVICE_LIMIT_DEFAULT
WS_MAX_CLIENTS=$WS_MAX_CLIENTS
WS_IDLE_TIMEOUT=$WS_IDLE_TIMEOUT
HOST_DOMAIN="$HOST_DOMAIN"
PUBLIC_IPV4="$PUBLIC_IPV4"
SLOWDNS_ENABLED=$SLOWDNS_ENABLED
NS_DOMAIN="$NS_DOMAIN"
SHARE_PORT=$SHARE_PORT
AUTO_REBOOT=$AUTO_REBOOT
HEALTH_FAIL_THRESHOLD=$HEALTH_FAIL_THRESHOLD
HEALTH_REBOOT_COOLDOWN=$HEALTH_REBOOT_COOLDOWN
EOF
 chmod 600 "$CONF"; printf '%s\n' "$HOST_DOMAIN">/etc/vps-domain.txt; }
svc(){ timeout 2 systemctl is-active --quiet "$1" 2>/dev/null && echo ONLINE || echo OFFLINE; }
badge(){ [[ $1 == ONLINE ]] && echo -e "${C2}● ONLINE${N}" || echo -e "${CR}○ OFFLINE${N}"; }
pause(){ echo; read -r -p ' Press Enter... ' _; }
valid(){ [[ ${1:-} =~ ^[0-9]+$ ]] && ((1<=10#$1 && 10#$1<=65535)); }
has(){ case ",$1," in *",$2,"*) return 0;; *) return 1;; esac; }
allow_tcp(){ iptables -C INPUT -p tcp --dport "$1" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$1" -j ACCEPT 2>/dev/null || true; command -v ufw >/dev/null 2>&1 && ufw allow "$1/tcp" >/dev/null 2>&1 || true; }

header(){
 load; local ip ram up users
 ip=${PUBLIC_IPV4:-$(hostname -I 2>/dev/null|awk '{print $1}')}; ram=$(free -m|awk '/Mem:/{printf "%d/%d MB",$3,$2}'); up=$(uptime -p|sed 's/^up //'); users=$(awk -F: '$3>=1000&&$1!="nobody"{n++}END{print n+0}' /etc/passwd)
 clear
 echo -e "${C1}╭────────────────────────────────────────────────────────────╮${N}"
 echo -e "${C1}│${N} ${B}${C4}N4 VPS PANEL${N} ${C5}• Core 2026 ${N}                      ${C1}│${N}"
 echo -e "${C1}╰────────────────────────────────────────────────────────────╯${N}"
 printf ' %-10s %-22s %-8s %s\n' Host "$HOST_DOMAIN" IPv4 "$ip"
 printf ' %-10s %-22s %-8s %s\n' RAM "$ram" Users "$users"
 printf ' %-10s %-22s\n' Uptime "$up"
 echo -e "${CP}──────────────────────────────────────────────────────────────${N}"
 printf ' %-22s %-17b %s\n' 'Admin SSH :22' "$(badge "$(svc ssh)")" Protected
 printf ' %-22s %-17b %s\n' "VPN SSH :$VPN_SSH_PORT" "$(badge "$(svc vpn-ssh)")" Direct
 printf ' %-22s %-17b %s\n' WebSocket "$(badge "$(svc ws-proxy)")" "$WS_PORTS"
 printf ' %-22s %-17b %s\n' "Hybrid SSH :$HYBRID_PORT" "$(badge "$(svc ws-proxy)")" 'Direct + Payload'
 printf ' %-22s %-17b %s\n' Dropbear "$(badge "$(svc dropbear)")" 'Hybrid backend + extra ports'
 if [[ $SLOWDNS_ENABLED -eq 1 ]]; then printf ' %-22s %-17b %s\n' 'SlowDNS :53/udp' "$(badge "$(svc slowdns)")" "$NS_DOMAIN"; else printf ' %-22s %-17b %s\n' 'SlowDNS' "${C5}○ DISABLED${N}" '-'; fi
 printf ' %-22s %-17b %s\n' 'Share Server' "$(badge "$(svc n4-share)")" ":$SHARE_PORT"
 echo -e "${CP}──────────────────────────────────────────────────────────────${N}"
}

checkport(){ local p=$1 t=$2; valid "$p" || { echo ' Invalid port.'; return 1; }; [[ $p != 22 ]] || { echo ' TCP/22 is reserved for Admin SSH.'; return 1; }; case $t in vpn) [[ $p != "$HYBRID_PORT" ]] || { echo " TCP/$HYBRID_PORT is reserved for Hybrid."; return 1; }; has "$WS_PORTS" "$p" && { echo ' Conflict with WebSocket.'; return 1; }; has "$DROPBEAR_PORTS" "$p" && { echo ' Conflict with Dropbear.'; return 1; };; ws) [[ $p != "$VPN_SSH_PORT" && $p != "$HYBRID_PORT" ]] || { echo ' Reserved/conflicting port.'; return 1; }; has "$DROPBEAR_PORTS" "$p" && { echo ' Conflict with Dropbear.'; return 1; };; drop) [[ $p != "$VPN_SSH_PORT" ]] || { echo ' Conflict with VPN SSH.'; return 1; }; if [[ $p != "$HYBRID_PORT" ]] && has "$WS_PORTS" "$p"; then echo ' Conflict with WebSocket.'; return 1; fi;; esac; }
refresh_shares(){ local f u; for f in "$SHARES"/*.json; do [[ -f $f ]]||continue; u=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("username",""))' "$f" 2>/dev/null||true); [[ -n $u ]] && share_update_user "$u" '' ''; done; }
apply_vpn(){ sed -i "s/^Port .*/Port $VPN_SSH_PORT/" /etc/ssh/sshd_vpn_config; /usr/sbin/sshd -t -f /etc/ssh/sshd_vpn_config || return 1; if [[ $SLOWDNS_ENABLED -eq 1 && -f /etc/systemd/system/slowdns.service ]]; then sed -i -E "s#127\\.0\\.0\\.1:[0-9]+#127.0.0.1:$VPN_SSH_PORT#" /etc/systemd/system/slowdns.service; fi; allow_tcp "$VPN_SSH_PORT"; save; systemctl daemon-reload; systemctl restart vpn-ssh; [[ $SLOWDNS_ENABLED -eq 1 ]] && systemctl restart slowdns || true; systemctl restart ws-proxy; refresh_shares; }
apply_ws(){ save; local p; IFS=, read -ra a<<<"$WS_PORTS"; for p in "${a[@]}"; do allow_tcp "$p"; done; systemctl restart ws-proxy; refresh_shares; }
apply_drop(){ local args=" -p 127.0.0.1:$DROPBEAR_INTERNAL_PORT" p; IFS=, read -ra a<<<"$DROPBEAR_PORTS"; for p in "${a[@]}"; do allow_tcp "$p"; [[ $p == "$HYBRID_PORT" ]] || args+=" -p $p"; done; cat >/etc/default/dropbear <<EOF
NO_START=0
DROPBEAR_PORT=0
DROPBEAR_EXTRA_ARGS="$args -w -g"
DROPBEAR_BANNER="/etc/issue.net"
EOF
 allow_tcp "$HYBRID_PORT"; save; systemctl restart dropbear; systemctl restart ws-proxy; refresh_shares; }

sync_limits(){ local f=/etc/security/limits.d/99-n4vpn-users.conf q u l; : >"$f"; for q in "$DEV"/*; do [[ -f $q ]]||continue; u=$(basename "$q"); l=$(cat "$q" 2>/dev/null||echo 0); [[ $l =~ ^[0-9]+$ ]]||continue; ((l>0))&&echo "$u hard maxlogins $l">>"$f"; done; }
share_perm(){ local f=${1:-}; id -u n4share >/dev/null 2>&1||return 0; [[ -n $f && -f $f ]]&&{ chown n4share:n4share "$f"; chmod 640 "$f"; }; chown n4share:n4share "$SHARES" 2>/dev/null||true; chmod 750 "$SHARES" 2>/dev/null||true; }
share_make(){ local u=$1 pass=$2 exp=$3 token epoch file; token=$(openssl rand -hex 24); epoch=$(date -d "$exp 23:59:59" +%s); file="$SHARES/$token.json"; python3 - "$file" "$u" "$pass" "$exp" "$epoch" "$HOST_DOMAIN" "$VPN_SSH_PORT" "$WS_PORTS" "$HYBRID_PORT" "$DROPBEAR_PORTS" "${NS_DOMAIN:-}" <<'PY'
import json,sys
p,u,pw,ed,ee,h,ssh,ws,hy,db,ns=sys.argv[1:]
d={'username':u,'password':pw,'expires_date':ed,'expires_epoch':int(ee),'host':h,'ssh_port':ssh,'ws_ports':ws,'hybrid_port':hy,'dropbear_ports':db,'slowdns_ns':ns}
with open(p,'w',encoding='utf-8') as f: json.dump(d,f,ensure_ascii=False)
PY
 share_perm "$file"; echo "http://$HOST_DOMAIN:$SHARE_PORT/s/$token"; }
share_update_user(){ local u=$1 newpass=${2:-} newexp=${3:-} f; for f in "$SHARES"/*.json; do [[ -f $f ]]||continue; python3 - "$f" "$u" "$newpass" "$newexp" "$HOST_DOMAIN" "$VPN_SSH_PORT" "$WS_PORTS" "$HYBRID_PORT" "$DROPBEAR_PORTS" "${NS_DOMAIN:-}" <<'PY'
import json,sys,datetime
p,u,pw,exp,h,ssh,ws,hy,db,ns=sys.argv[1:]
try:
 d=json.load(open(p,encoding='utf-8'))
except Exception: sys.exit(0)
if d.get('username')!=u: sys.exit(0)
if pw: d['password']=pw
if exp:
 d['expires_date']=exp; d['expires_epoch']=int(datetime.datetime.strptime(exp+' 23:59:59','%Y-%m-%d %H:%M:%S').timestamp())
d.update({'host':h,'ssh_port':ssh,'ws_ports':ws,'hybrid_port':hy,'dropbear_ports':db,'slowdns_ns':ns})
# Remove retired WireGuard fields from older share files.
for k in ('wg_endpoint','wg_mtu','wireguard_config'): d.pop(k,None)
json.dump(d,open(p,'w',encoding='utf-8'),ensure_ascii=False)
PY
 share_perm "$f"; done; }

create(){ header; echo -e " ${CB}${B}CREATE ACCOUNT${N}"; read -r -p ' Username: ' u; [[ $u =~ ^[a-z_][a-z0-9_-]{1,31}$ ]] || { echo ' Invalid username. Use 2-32 chars: a-z, 0-9, _ or -.'; pause; return; }; id "$u" &>/dev/null&&{ echo ' Account already exists.'; pause; return; }; read -r -s -p ' Password: ' p; echo; [[ -n $p ]]||{ echo ' Password required.'; pause; return; }; read -r -p ' Days [30]: ' d; d=${d:-30}; read -r -p ' GB limit in GB [0=unlimited]: ' gb; gb=${gb:-0}; read -r -p " Session limit [$DEVICE_LIMIT_DEFAULT]: " l; l=${l:-$DEVICE_LIMIT_DEFAULT}; [[ $d =~ ^[0-9]+$ && $l =~ ^[0-9]+$ && $gb =~ ^[0-9]+$ ]]||{ echo ' Invalid number.'; pause; return; }; exp=$(date -d "+$d days" +%F); useradd -M -s /bin/false -e "$exp" -p "$(openssl passwd -6 "$p")" "$u"||{ echo ' Create failed.'; pause; return; }; echo "$l">"$DEV/$u"; sync_limits; mkdir -p "$N4/accounts"; printf 'GB_LIMIT=%s\nUSED_BYTES=0\nEXPIRY=%s\n' "$gb" "$exp" > "$N4/accounts/$u"; chmod 600 "$N4/accounts/$u"; link=$(share_make "$u" "$p" "$exp"); echo; echo -e "${C2}${B} ✓ ACCOUNT CREATED${N}"; echo " User       : $u"; echo " Expires    : $exp"; echo " GB limit   : $gb GB (0=unlimited)"; echo " SSH        : $HOST_DOMAIN:$VPN_SSH_PORT"; echo " Hybrid     : $HOST_DOMAIN:$HYBRID_PORT"; [[ $SLOWDNS_ENABLED -eq 1 ]]&&echo " SlowDNS    : $NS_DOMAIN"; echo; echo -e "${C1} Private share link:${N}"; echo " $link"; echo -e "${C5} Link expires automatically with this account.${N}"; pause; }
renew(){ header; read -r -p ' Username: ' u; id "$u" &>/dev/null||{ echo ' Not found.'; pause; return; }; read -r -p ' Add days: ' d; read -r -p ' New GB limit in GB [0=unlimited]: ' gb; gb=${gb:-0}; [[ $d =~ ^[0-9]+$ && $gb =~ ^[0-9]+$ ]]||{ echo ' Invalid days.'; pause; return; }; cur=$(chage -l "$u"|awk -F': ' '/Account expires/{print $2}'); base=$(date +%F); [[ $cur != never && -n $cur ]]&&base=$(date -d "$cur" +%F 2>/dev/null||date +%F); [[ $(date -d "$base" +%s) -lt $(date +%s) ]]&&base=$(date +%F); new=$(date -d "$base +$d days" +%F); chage -E "$new" "$u"; share_update_user "$u" '' "$new"; mkdir -p "$N4/accounts"; printf 'GB_LIMIT=%s\nUSED_BYTES=0\nEXPIRY=%s\n' "$gb" "$new" > "$N4/accounts/$u"; chmod 600 "$N4/accounts/$u"; echo " New expiry: $new"; echo " New GB limit: $gb GB (used bytes reset to 0)"; pause; }
passwd_user(){ header; read -r -p ' Username: ' u; id "$u" &>/dev/null||{ echo ' Not found.'; pause; return; }; read -r -s -p ' New password: ' p; echo; [[ -n $p ]]||{ echo ' Password required.'; pause; return; }; usermod -p "$(openssl passwd -6 "$p")" "$u"; share_update_user "$u" "$p" ''; echo ' Password updated.'; pause; }
deluser_n4(){ header; read -r -p ' Username: ' u; id "$u" &>/dev/null||{ echo ' Not found.'; pause; return; }; read -r -p " Delete $u? [y/N]: " x; [[ $x =~ ^[Yy]$ ]]||return; pkill -KILL -u "$u" 2>/dev/null||true; userdel -f "$u"; rm -f "$DEV/$u"; rm -f "$N4/accounts/$u"; /usr/local/sbin/n4-cleanup "$u" >/dev/null 2>&1||true; sync_limits; echo ' Account and share link removed.'; pause; }
listusers(){ header; printf " ${B}%-18s %-15s %-8s %-8s${N}\n" USER EXPIRY LIMIT GB; echo ' ------------------------------------------------'; while IFS=: read -r u _ uid _ _ _ _; do ((uid>=1000))||continue; [[ $u == nobody ]]&&continue; exp=$(chage -l "$u" 2>/dev/null|awk -F': ' '/Account expires/{print $2}'); l=$(cat "$DEV/$u" 2>/dev/null||echo "$DEVICE_LIMIT_DEFAULT"); g=$(awk -F= '/^GB_LIMIT=/{print $2;exit}' "$N4/accounts/$u" 2>/dev/null||echo "-"); printf ' %-18s %-15s %-8s %-8s\n' "$u" "${exp:0:15}" "$l" "$g"; done </etc/passwd; pause; }
limit(){ header; read -r -p ' Username: ' u; id "$u" &>/dev/null||{ echo ' Not found.'; pause; return; }; read -r -p ' Concurrent session limit (0=unlimited): ' l; [[ $l =~ ^[0-9]+$ ]]||{ echo ' Invalid.'; pause; return; }; echo "$l">"$DEV/$u"; sync_limits; echo ' Session limit saved.'; pause; }
connections(){ header; echo -e " ${CB}${B}ONLINE CONNECTIONS${N}"; echo; timeout 4 ss -H -tn state established 2>/dev/null|head -n100||true; pause; }

ports_menu(){ while true; do header; echo -e " ${CB}${B}PORT MANAGER${N}"; echo "  Hybrid TCP/$HYBRID_PORT = Direct Dropbear + HTTP/WS Payload"; echo; echo "  [1] VPN SSH              $VPN_SSH_PORT"; echo "  [2] Replace WS ports     $WS_PORTS"; echo '  [3] Add WS port'; echo '  [4] Remove WS port'; echo "  [5] Replace Dropbear     $DROPBEAR_PORTS"; echo '  [6] Add Dropbear port'; echo '  [7] Remove Dropbear port'; echo '  [0] Back'; read -r -p ' Select › ' x; case $x in 1) read -r -p ' New VPN SSH port: ' p; checkport "$p" vpn||{ pause; continue; }; VPN_SSH_PORT=$p; apply_vpn; pause;; 2) read -r -p ' WS ports CSV: ' v; ok=1; IFS=, read -ra a<<<"$v"; for p in "${a[@]}"; do checkport "$p" ws||ok=0; done; ((ok))&&{ WS_PORTS=$v; apply_ws; }; pause;; 3) read -r -p ' WS port: ' p; checkport "$p" ws||{ pause; continue; }; has "$WS_PORTS" "$p"||WS_PORTS="$WS_PORTS,$p"; apply_ws; pause;; 4) read -r -p ' WS port: ' p; WS_PORTS=$(tr ',' '\n'<<<"$WS_PORTS"|grep -vx "$p"|paste -sd, -); [[ -n $WS_PORTS ]]||WS_PORTS=80; apply_ws; pause;; 5) read -r -p ' Dropbear ports CSV (443 stays hybrid): ' v; has "$v" "$HYBRID_PORT"||v="$HYBRID_PORT${v:+,$v}"; ok=1; IFS=, read -ra a<<<"$v"; for p in "${a[@]}"; do checkport "$p" drop||ok=0; done; ((ok))&&{ DROPBEAR_PORTS=$v; apply_drop; }; pause;; 6) read -r -p ' Dropbear port: ' p; checkport "$p" drop||{ pause; continue; }; has "$DROPBEAR_PORTS" "$p"||DROPBEAR_PORTS="$DROPBEAR_PORTS,$p"; apply_drop; pause;; 7) read -r -p ' Dropbear port: ' p; if [[ $p == "$HYBRID_PORT" ]]; then echo ' Hybrid 443 cannot be removed.'; else DROPBEAR_PORTS=$(tr ',' '\n'<<<"$DROPBEAR_PORTS"|grep -vx "$p"|paste -sd, -); has "$DROPBEAR_PORTS" "$HYBRID_PORT"||DROPBEAR_PORTS="$HYBRID_PORT${DROPBEAR_PORTS:+,$DROPBEAR_PORTS}"; apply_drop; fi; pause;; 0) return;; esac; done; }
slowdns_menu(){ while true; do header; echo -e " ${CB}${B}SLOWDNS${N}"; echo "  Status : $SLOWDNS_ENABLED"; echo "  NS     : ${NS_DOMAIN:-none}"; echo '  [1] Change NS'; echo '  [2] Restart'; echo '  [3] Logs'; echo '  [0] Back'; read -r -p ' Select › ' x; case $x in 1) read -r -p ' NS domain: ' n; [[ -n $n ]]||continue; NS_DOMAIN=$n; SLOWDNS_ENABLED=1; save; echo "$n">/etc/slowdns/nsdomain.txt; sed -i -E "s#ExecStart=.*#ExecStart=/etc/slowdns/dnstt-server -udp 0.0.0.0:53 -privkey-file /etc/slowdns/server.key $NS_DOMAIN 127.0.0.1:$VPN_SSH_PORT#" /etc/systemd/system/slowdns.service; systemctl daemon-reload; systemctl enable --now slowdns; refresh_shares; pause;; 2) systemctl restart slowdns; pause;; 3) journalctl -u slowdns -n50 --no-pager; pause;; 0) return;; esac; done; }
services(){ while true; do header; echo -e " ${CB}${B}SERVICE / RECOVERY${N}"; echo '  [1] Restart VPN SSH'; echo '  [2] Restart WebSocket / Hybrid'; echo '  [3] Restart Dropbear'; echo '  [4] Restart SlowDNS'; echo '  [5] Restart Share Server'; echo '  [6] Restart all core services'; echo '  [7] Run health check now'; echo '  [8] Recent warnings'; echo '  [9] Auto-reboot settings'; echo '  [0] Back'; read -r -p ' Select › ' x; case $x in 1) systemctl restart vpn-ssh;; 2) systemctl restart ws-proxy;; 3) systemctl restart dropbear;; 4) systemctl restart slowdns;; 5) systemctl restart n4-share;; 6) systemctl restart vpn-ssh dropbear ws-proxy n4-share; [[ $SLOWDNS_ENABLED -eq 1 ]]&&systemctl restart slowdns||true;; 7) /usr/local/sbin/n4-healthcheck; echo ' Health check completed.';; 8) journalctl -u vpn-ssh -u ws-proxy -u dropbear -u slowdns -u n4-share -p warning -n100 --no-pager;; 9) echo " Auto reboot: $AUTO_REBOOT"; echo " Failure threshold: $HEALTH_FAIL_THRESHOLD checks"; echo " Reboot cooldown: $HEALTH_REBOOT_COOLDOWN seconds"; read -r -p ' Enable auto reboot? [y/N]: ' a; [[ $a =~ ^[Yy]$ ]]&&AUTO_REBOOT=1||AUTO_REBOOT=0; save; echo ' Saved.';; 0) return;; esac; pause; done; }
domain(){ header; read -r -p " New domain/IP [$HOST_DOMAIN]: " h; [[ -n $h ]]||return; h=${h#http://}; h=${h#https://}; h=${h%%/*}; HOST_DOMAIN=$h; save; refresh_shares; echo ' Domain updated.'; pause; }
update_system(){ header; echo -e " ${CB}${B}UPDATE N4 VPN${N}"; echo ' Existing users/configs are backed up before update.'; read -r -p ' Continue update from GitHub? [y/N]: ' x; [[ $x =~ ^[Yy]$ ]]||return; if [[ -x /usr/local/bin/n4-update ]]; then /usr/local/bin/n4-update; else curl -fsSL "https://raw.githubusercontent.com/Nanda-N4/installer2/main/update.sh?cb=$(date +%s)" -o /tmp/n4-update && chmod +x /tmp/n4-update && /tmp/n4-update; fi; pause; }
bot_menu(){ header; echo -e " ${CB}${B}TG BOT${N}"; if [[ -f /etc/n4vpn/bot.conf ]]; then echo " Status : $(systemctl is-active n4-bot 2>/dev/null || echo unknown)"; else echo ' Status : NOT SET UP'; fi; echo '  [1] Setup / Re-setup Bot (Token + TG User ID)'; echo '  [2] Restart Bot'; echo '  [3] Stop Bot'; echo '  [4] Bot Logs'; echo '  [0] Back'; read -r -p ' Select › ' x; case $x in 1) if [[ -x /usr/local/bin/bot-setup.sh ]]; then /usr/local/bin/bot-setup.sh; else echo 'bot-setup.sh not found.'; fi; pause;; 2) systemctl restart n4-bot; echo 'Bot restarted.'; pause;; 3) systemctl stop n4-bot; echo 'Bot stopped.'; pause;; 4) journalctl -u n4-bot -n 50 --no-pager; pause;; 0) return;; esac; }
account_menu(){ while true; do header; echo -e " ${CB}${B}ACCOUNT MANAGER${N}"; echo '  [1] Create account        [2] Renew account'; echo '  [3] Change password       [4] Delete account'; echo '  [5] Account list          [6] Session limit'; echo '  [0] Back'; read -r -p ' Select › ' x; case $x in 1) create;; 2) renew;; 3) passwd_user;; 4) deluser_n4;; 5) listusers;; 6) limit;; 0) return;; esac; done; }
main(){ while true; do header; echo -e " ${CB}${B}MANAGEMENT${N}"; echo '  [1] Account Manager'; echo '  [2] Online Connections'; echo '  [3] Port Manager'; echo '  [4] Service / Recovery'; echo '  [5] SlowDNS'; echo '  [6] Change Domain'; echo '  [7] Update N4 VPN'; echo '  [8] TG BOT'; echo; echo '  [0] Exit'; echo -e "${CP}──────────────────────────────────────────────────────────────${N}"; read -r -p ' Select › ' x; case $x in 1) account_menu;; 2) connections;; 3) ports_menu;; 4) services;; 5) slowdns_menu;; 6) domain;; 7) update_system;; 8) bot_menu;; 0) clear; return;; *) sleep .15;; esac; done; }
if [[ ${1:-} == --refresh-shares ]]; then load; refresh_shares; exit $?; fi
main "$@"
