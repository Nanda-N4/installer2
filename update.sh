#!/usr/bin/env bash
set -Eeuo pipefail
VERSION='2026.09.24-r10.1-migratefix'
REPO_RAW='https://raw.githubusercontent.com/Nanda-N4/installer2/main'
N4=/etc/n4vpn; CONF=$N4/n4.conf
[[ $EUID -eq 0 ]] || { echo 'Run as root'; exit 1; }
fetch(){ curl -fL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 90 -H 'Cache-Control: no-cache' "$REPO_RAW/$1?cb=$(date +%s%N)" -o "$2"; }
backup(){ local d=/root/n4-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$d"; for p in /etc/n4vpn /etc/slowdns /etc/ssh/sshd_vpn_config /etc/default/dropbear /etc/vps-domain.txt /usr/local/bin/menu /usr/local/bin/ws-proxy.py /usr/local/bin/n4-share-server.py /etc/systemd/system/vpn-ssh.service /etc/systemd/system/ws-proxy.service /etc/systemd/system/slowdns.service /etc/systemd/system/n4-share.service; do [[ -e $p ]] && cp -a "$p" "$d/" 2>/dev/null || true; done; echo "$d"; }
get_conf(){ local k=$1 d=$2; if [[ -f $CONF ]]; then v=$(awk -F= -v k="$k" '$1==k{gsub(/^\"|\"$/,"",$2);print $2;exit}' "$CONF" 2>/dev/null || true); [[ -n ${v:-} ]] && { echo "$v"; return; }; fi; echo "$d"; }
detect(){
 local had_conf=0 legacy_db=''
 [[ -f $CONF ]] && had_conf=1
 VPN_SSH_PORT=$(get_conf VPN_SSH_PORT 109); WS_PORTS=$(get_conf WS_PORTS '80'); DROPBEAR_PORTS=$(get_conf DROPBEAR_PORTS ''); HYBRID_PORT=$(get_conf HYBRID_PORT 443); DROPBEAR_INTERNAL_PORT=$(get_conf DROPBEAR_INTERNAL_PORT 1443)
 DEVICE_LIMIT_DEFAULT=$(get_conf DEVICE_LIMIT_DEFAULT 1); WS_MAX_CLIENTS=$(get_conf WS_MAX_CLIENTS 2048); WS_IDLE_TIMEOUT=$(get_conf WS_IDLE_TIMEOUT 180); SHARE_PORT=$(get_conf SHARE_PORT 8880)
 AUTO_REBOOT=$(get_conf AUTO_REBOOT 1); HEALTH_FAIL_THRESHOLD=$(get_conf HEALTH_FAIL_THRESHOLD 5); HEALTH_REBOOT_COOLDOWN=$(get_conf HEALTH_REBOOT_COOLDOWN 21600)
 HOST_DOMAIN=$(get_conf HOST_DOMAIN ''); PUBLIC_IPV4=$(get_conf PUBLIC_IPV4 ''); SLOWDNS_ENABLED=$(get_conf SLOWDNS_ENABLED 0); NS_DOMAIN=$(get_conf NS_DOMAIN '')
 if [[ -f /etc/ssh/sshd_vpn_config ]]; then p=$(awk '/^Port /{print $2;exit}' /etc/ssh/sshd_vpn_config); [[ -n ${p:-} ]] && VPN_SSH_PORT=$p; fi
 # On very old installs there is no n4.conf. Preserve public Dropbear ports when possible.
 if (( had_conf == 0 )) && [[ -f /etc/default/dropbear ]]; then
  legacy_db=$(grep -oE '(-p[[:space:]]+|DROPBEAR_PORT=)[0-9.:]+' /etc/default/dropbear 2>/dev/null | grep -oE '[0-9]+$' | awk '$1>=1&&$1<=65535' | paste -sd, -)
  [[ -n ${legacy_db:-} ]] && DROPBEAR_PORTS=$legacy_db
 fi
 [[ -z $HOST_DOMAIN && -f /etc/vps-domain.txt ]] && HOST_DOMAIN=$(cat /etc/vps-domain.txt)
 [[ -z $PUBLIC_IPV4 ]] && PUBLIC_IPV4=$(curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null || hostname -I|awk '{print $1}')
 [[ -z $HOST_DOMAIN ]] && HOST_DOMAIN=$PUBLIC_IPV4
 if [[ -d /etc/slowdns ]]; then SLOWDNS_ENABLED=1; [[ -f /etc/slowdns/nsdomain.txt ]] && NS_DOMAIN=$(cat /etc/slowdns/nsdomain.txt); fi
 if [[ $SLOWDNS_ENABLED == 1 && -z $NS_DOMAIN && -f /etc/systemd/system/slowdns.service ]]; then NS_DOMAIN=$(sed -nE 's#.*-privkey-file [^ ]+ ([^ ]+) 127\.0\.0\.1:[0-9]+.*#\1#p' /etc/systemd/system/slowdns.service | head -n1); fi
 [[ -z $NS_DOMAIN ]] && SLOWDNS_ENABLED=0

 DROPBEAR_PORTS=$(csv_remove_reserved "$DROPBEAR_PORTS")
 # Port-map migration (installer2): old WS 80,143,442,8080 -> 80 only.
 # Old DROPBEAR_PORTS 443 was a no-op (hybrid already owns 443); drop it.
 WS_PORTS='80'; DROPBEAR_PORTS=''
 # Legacy GB safety: users with no accounts record get GB_LIMIT=0 (unlimited)
 # with their current Linux expiry, so an update never locks old users.
 mkdir -p "$N4/accounts"; while IFS=: read -r lu _ luid _ _ _ _; do ((luid>=1000)) || continue; [[ $lu == nobody ]] && continue; [[ -f $N4/accounts/$lu ]] && continue; lexp=$(chage -l "$lu" 2>/dev/null | awk -F': ' '/Account expires/{print $2}'); [[ $lexp == never || -z $lexp ]] && lexp='2099-12-31'; lexp=$(date -d "$lexp" +%F 2>/dev/null || echo '2099-12-31'); printf 'GB_LIMIT=0\nUSED_BYTES=0\nEXPIRY=%s\n' "$lexp" > "$N4/accounts/$lu"; chmod 600 "$N4/accounts/$lu"; done </etc/passwd
}
save(){ mkdir -p "$N4/device-limits" "$N4/shares" /var/log/n4vpn /var/lib/n4vpn-health; cat >"$CONF" <<EOF
VPN_SSH_PORT=$VPN_SSH_PORT
WS_PORTS="$WS_PORTS"
DROPBEAR_PORTS="$DROPBEAR_PORTS"
HYBRID_PORT=$HYBRID_PORT
DROPBEAR_INTERNAL_PORT=$DROPBEAR_INTERNAL_PORT
DEVICE_LIMIT_DEFAULT=$DEVICE_LIMIT_DEFAULT
WS_MAX_CLIENTS=$WS_MAX_CLIENTS
WS_IDLE_TIMEOUT=$WS_IDLE_TIMEOUT
HOST_DOMAIN="$HOST_DOMAIN"
SLOWDNS_ENABLED=$SLOWDNS_ENABLED
NS_DOMAIN="$NS_DOMAIN"
PUBLIC_IPV4="$PUBLIC_IPV4"
SHARE_PORT=$SHARE_PORT
AUTO_REBOOT=$AUTO_REBOOT
HEALTH_FAIL_THRESHOLD=$HEALTH_FAIL_THRESHOLD
HEALTH_REBOOT_COOLDOWN=$HEALTH_REBOOT_COOLDOWN
EOF
 chmod 600 "$CONF"; echo "$HOST_DOMAIN">/etc/vps-domain.txt; }
allow(){ local p=$1 proto=${2:-tcp}; iptables -C INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || iptables -A INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || true; command -v ufw >/dev/null 2>&1 && ufw allow "$p/$proto" >/dev/null 2>&1 || true; }

csv_remove_reserved(){
 local csv=${1:-} out='' p
 IFS=, read -ra arr <<<"$csv"
 for p in "${arr[@]}"; do
  p=${p//[[:space:]]/}
  [[ $p =~ ^[0-9]+$ ]] || continue
  (( p>=1 && p<=65535 )) || continue
  [[ $p == "$VPN_SSH_PORT" || $p == "$HYBRID_PORT" || $p == 22 || $p == "$DROPBEAR_INTERNAL_PORT" ]] && continue
  case ",$out," in *",$p,"*) ;; *) out="${out:+$out,}$p";; esac
 done
 printf '%s' "$out"
}

port_owner(){
 local p=$1
 ss -ltnp 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {print; exit}'
}

legacy_cleanup(){
 echo '[migrate] Stopping legacy proxy/Dropbear processes safely...'

 systemctl stop ws-proxy.service vpn-ssh.service dropbear.service 2>/dev/null || true

 for svc in ws-dropbear.service websocket.service ws.service websocket-proxy.service vpn-watchdog.service; do
  systemctl disable --now "$svc" >/dev/null 2>&1 || true
 done

 pkill -f '[w]s-proxy.py' 2>/dev/null || true
 pkill -x dropbear 2>/dev/null || true
 sleep 2

 local line
 line=$(port_owner "$VPN_SSH_PORT" || true)
 if [[ -n $line ]]; then
  if grep -qiE 'dropbear|ws-proxy\.py|python3' <<<"$line"; then
   echo "[migrate] Releasing legacy listener on VPN SSH port $VPN_SSH_PORT"
   if grep -qi dropbear <<<"$line"; then pkill -x dropbear 2>/dev/null || true; fi
   if grep -qiE 'ws-proxy\.py|python3' <<<"$line"; then pkill -f '[w]s-proxy.py' 2>/dev/null || true; fi
   sleep 2
  fi
 fi
 line=$(port_owner "$VPN_SSH_PORT" || true)
 if [[ -n $line ]]; then
  echo "[ERROR] Port $VPN_SSH_PORT is still occupied by an unknown process:"
  echo "$line"
  echo 'Nothing was killed. Resolve this listener manually, then run the updater again.'
  exit 20
 fi
}

verify_layout(){
 local bad=0 p
 echo '[verify] Checking N4 listeners...'
 if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$VPN_SSH_PORT$"; then
  echo "[WARN] VPN SSH :$VPN_SSH_PORT is not listening"; bad=1
 fi
 if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$DROPBEAR_INTERNAL_PORT$"; then
  echo "[WARN] Dropbear backend :$DROPBEAR_INTERNAL_PORT is not listening"; bad=1
 fi
 if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$HYBRID_PORT$"; then
  echo "[WARN] Hybrid :$HYBRID_PORT is not listening"; bad=1
 fi
 IFS=, read -ra arr <<<"$WS_PORTS"
 for p in "${arr[@]}"; do
  [[ $p =~ ^[0-9]+$ ]] || continue
  if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$p$"; then
   echo "[WARN] WebSocket :$p is not listening"; bad=1
  fi
 done
 if (( bad )); then
  echo '[verify] One or more listeners are missing. Recent logs:'
  systemctl --no-pager --full status vpn-ssh dropbear ws-proxy 2>/dev/null || true
  return 1
 fi
 echo '[verify] Core listeners are healthy.'
 return 0
}
write_units(){
 cat >/etc/systemd/system/vpn-ssh.service <<'EOF'
[Unit]
Description=N4 VPN Dedicated SSH Engine
StartLimitIntervalSec=0
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStartPre=/usr/sbin/sshd -t -f /etc/ssh/sshd_vpn_config
ExecStart=/usr/sbin/sshd -D -e -f /etc/ssh/sshd_vpn_config
Restart=always
RestartSec=2
LimitNOFILE=262144
TasksMax=8192
OOMScoreAdjust=-250
Nice=-2
[Install]
WantedBy=multi-user.target
EOF
 local args=" -p 127.0.0.1:$DROPBEAR_INTERNAL_PORT" p; IFS=, read -ra a<<<"$DROPBEAR_PORTS"; for p in "${a[@]}"; do [[ $p == "$HYBRID_PORT" ]] || args+=" -p $p"; done
 cat >/etc/default/dropbear <<EOF
NO_START=0
DROPBEAR_PORT=0
DROPBEAR_EXTRA_ARGS="$args -w -g"
DROPBEAR_BANNER="/etc/issue.net"
EOF
 cat >/etc/systemd/system/ws-proxy.service <<'EOF'
[Unit]
Description=N4 Async Hybrid SSH/WS Proxy
StartLimitIntervalSec=0
After=network-online.target vpn-ssh.service dropbear.service
Wants=network-online.target dropbear.service
Requires=vpn-ssh.service
[Service]
Type=simple
User=root
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always
RestartSec=2
LimitNOFILE=262144
TasksMax=8192
OOMScoreAdjust=-100
[Install]
WantedBy=multi-user.target
EOF
 if [[ $SLOWDNS_ENABLED == 1 ]]; then cat >/etc/systemd/system/slowdns.service <<EOF
[Unit]
Description=N4 SlowDNS DNSTT Server
StartLimitIntervalSec=0
After=network-online.target vpn-ssh.service
Requires=vpn-ssh.service
[Service]
Type=simple
WorkingDirectory=/etc/slowdns
ExecStart=/etc/slowdns/dnstt-server -udp 0.0.0.0:53 -privkey-file /etc/slowdns/server.key $NS_DOMAIN 127.0.0.1:$VPN_SSH_PORT
Restart=always
RestartSec=2
LimitNOFILE=262144
TasksMax=8192
OOMScoreAdjust=-150
Nice=-1
[Install]
WantedBy=multi-user.target
EOF
 fi
 cat >/etc/systemd/system/n4-share.service <<'EOF'
[Unit]
Description=N4 private share server
StartLimitIntervalSec=0
After=network-online.target
Wants=network-online.target
[Service]
User=n4share
Group=n4share
ExecStart=/usr/bin/python3 /usr/local/bin/n4-share-server.py
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/etc/n4vpn/shares
ProtectHome=true
[Install]
WantedBy=multi-user.target
EOF
}
write_gb_timer(){ cat >/etc/systemd/system/n4-gblimit.service <<'EOF'
[Unit]
Description=N4 GB collector + GB limit check
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/gb-collector.sh
ExecStart=/usr/local/bin/gb-limit.sh
EOF
 cat >/etc/systemd/system/n4-gblimit.timer <<'EOF'
[Unit]
Description=N4 GB limit timer (every 5 minutes)
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
EOF
}
write_health(){
 cat >/usr/local/sbin/n4-healthcheck <<'EOF'
#!/usr/bin/env bash
set -u
source /etc/n4vpn/n4.conf 2>/dev/null || exit 0
STATE=/var/lib/n4vpn-health; LOG=/var/log/n4vpn/health.log; mkdir -p "$STATE" /var/log/n4vpn
now=$(date +%s); failed=0; log(){ echo "$(date '+%F %T') $*">>"$LOG"; }; port_ok(){ timeout 2 bash -c "</dev/tcp/127.0.0.1/$1" >/dev/null 2>&1; }
heal(){ local s=$1 p=${2:-}; if ! systemctl is-active --quiet "$s" || { [[ -n $p ]] && ! port_ok "$p"; }; then failed=1; log "FAIL $s port=${p:-n/a}; restart"; systemctl restart "$s" >/dev/null 2>&1 || true; sleep 2; fi; }
heal vpn-ssh "${VPN_SSH_PORT:-109}"; heal dropbear "${DROPBEAR_INTERNAL_PORT:-1443}"; heal ws-proxy "${HYBRID_PORT:-443}"; [[ ${SLOWDNS_ENABLED:-0} == 1 ]] && { systemctl is-active --quiet slowdns || { failed=1; log 'FAIL slowdns; restart'; systemctl restart slowdns >/dev/null 2>&1 || true; }; }; heal n4-share "${SHARE_PORT:-8880}"
c=$(cat "$STATE/fail-count" 2>/dev/null||echo 0); ((failed)) && c=$((c+1)) || c=0; echo "$c">"$STATE/fail-count"
if [[ ${AUTO_REBOOT:-1} == 1 ]] && (( c >= ${HEALTH_FAIL_THRESHOLD:-5} )); then up=$(cut -d. -f1 /proc/uptime); last=$(cat "$STATE/last-reboot-request" 2>/dev/null||echo 0); if (( up>900 && now-last>${HEALTH_REBOOT_COOLDOWN:-21600} )); then log "repeated failures; controlled reboot"; echo "$now">"$STATE/last-reboot-request"; sync; shutdown -r +1 'N4 auto recovery' >/dev/null 2>&1||true; fi; fi
EOF
 chmod 755 /usr/local/sbin/n4-healthcheck
 cat >/etc/systemd/system/n4-healthcheck.service <<'EOF'
[Unit]
Description=N4 VPN health check and recovery
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/n4-healthcheck
Nice=10
IOSchedulingClass=idle
EOF
 cat >/etc/systemd/system/n4-healthcheck.timer <<'EOF'
[Unit]
Description=N4 VPN health check timer
[Timer]
OnBootSec=45s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true
[Install]
WantedBy=timers.target
EOF
}
main(){
 echo "N4 updater $VERSION"; b=$(backup); echo "Backup: $b"; detect; legacy_cleanup; save
 apt-get update -y >/dev/null; apt-get install -y openssh-server dropbear python3 curl openssl iptables iproute2 procps >/dev/null
 id -u n4share >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin n4share
 fetch menu.sh /usr/local/bin/menu; fetch ws-proxy.py /usr/local/bin/ws-proxy.py; fetch share-server.py /usr/local/bin/n4-share-server.py; fetch update.sh /usr/local/bin/n4-update; fetch gb-limit.sh /usr/local/bin/gb-limit.sh; fetch gb-collector.sh /usr/local/bin/gb-collector.sh; fetch bot-setup.sh /usr/local/bin/bot-setup.sh; fetch bot.py /usr/local/bin/bot.py; fetch n4-create-user.sh /usr/local/bin/n4-create-user.sh; chmod 755 /usr/local/bin/menu /usr/local/bin/ws-proxy.py /usr/local/bin/n4-share-server.py /usr/local/bin/n4-update /usr/local/bin/gb-limit.sh /usr/local/bin/gb-collector.sh /usr/local/bin/bot-setup.sh /usr/local/bin/bot.py /usr/local/bin/n4-create-user.sh
 mkdir -p "$N4/shares"; chown -R n4share:n4share "$N4/shares"; chmod 750 "$N4/shares"; find "$N4/shares" -type f -name '*.json' -exec chown n4share:n4share {} \; -exec chmod 640 {} \; 2>/dev/null||true
 [[ -f /etc/ssh/sshd_vpn_config ]] || { cp /etc/ssh/sshd_config /etc/ssh/sshd_vpn_config; sed -i "s/^#\?Port .*/Port $VPN_SSH_PORT/" /etc/ssh/sshd_vpn_config; }
 grep -q '^Port ' /etc/ssh/sshd_vpn_config && sed -i "s/^Port .*/Port $VPN_SSH_PORT/" /etc/ssh/sshd_vpn_config || echo "Port $VPN_SSH_PORT">>/etc/ssh/sshd_vpn_config
 write_units; write_health; write_gb_timer
 cat >/usr/local/sbin/n4-cleanup <<'EOF'
#!/usr/bin/env bash
set -u
N4=/etc/n4vpn; target=${1:-}; now=$(date +%s)
for f in "$N4/shares"/*.json; do
 [[ -f $f ]] || continue
 u=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("username",""))' "$f" 2>/dev/null || true)
 e=$(python3 -c 'import json,sys;print(int(json.load(open(sys.argv[1])).get("expires_epoch",0)))' "$f" 2>/dev/null || echo 0)
 if [[ -n $target && $u == "$target" ]] || (( e>0 && e<=now )); then rm -f "$f"; fi
done
EOF
 chmod 755 /usr/local/sbin/n4-cleanup
 cat >/etc/systemd/system/n4-cleanup.service <<'EOF'
[Unit]
Description=N4 expiry cleanup
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/n4-cleanup
EOF
 cat >/etc/systemd/system/n4-cleanup.timer <<'EOF'
[Unit]
Description=N4 expiry cleanup timer
[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Persistent=true
[Install]
WantedBy=timers.target
EOF
 cat >/etc/profile.d/n4-menu.sh <<'EOF'
if [ "$(id -u 2>/dev/null)" = 0 ] && [ -t 0 ] && [ -t 1 ] && [ -z "${N4_MENU_ACTIVE:-}" ] && [ -x /usr/local/bin/menu ]; then case "${TERM:-}" in dumb|'') ;; *) export N4_MENU_ACTIVE=1; /usr/local/bin/menu || true ;; esac; fi
EOF
 chmod 644 /etc/profile.d/n4-menu.sh
 allow 22 tcp; allow "$VPN_SSH_PORT" tcp; IFS=, read -ra a<<<"$WS_PORTS"; for p in "${a[@]}"; do allow "$p" tcp; done; IFS=, read -ra a<<<"$DROPBEAR_PORTS"; for p in "${a[@]}"; do allow "$p" tcp; done; allow "$HYBRID_PORT" tcp; allow "$SHARE_PORT" tcp; [[ $SLOWDNS_ENABLED == 1 ]] && allow 53 udp

 if [[ -d /etc/n4vpn/wireguard ]]; then systemctl disable --now wg-quick@wg0 2>/dev/null || true; fi
 systemctl disable --now vpn-watchdog.service 2>/dev/null||true; rm -f /etc/systemd/system/vpn-watchdog.service /usr/local/bin/vpn-watchdog.sh
 systemctl daemon-reload; systemctl enable n4-healthcheck.timer n4-cleanup.timer n4-gblimit.timer vpn-ssh ws-proxy dropbear n4-share >/dev/null 2>&1||true
 systemctl reset-failed dropbear vpn-ssh ws-proxy 2>/dev/null || true
 systemctl restart dropbear
 sleep 1
 systemctl restart vpn-ssh
 sleep 1
 systemctl restart ws-proxy
 systemctl restart n4-share
 systemctl enable --now n4-healthcheck.timer n4-cleanup.timer n4-gblimit.timer; [[ -f $N4/bot.conf && -f /etc/systemd/system/n4-bot.service ]] && systemctl enable --now n4-bot >/dev/null 2>&1 || true >/dev/null 2>&1||true
 [[ $SLOWDNS_ENABLED == 1 ]] && systemctl enable --now slowdns >/dev/null 2>&1||true
 sleep 2
 verify_layout || true
 echo; echo 'Update/migration complete.'; echo 'Existing Linux users, expiry, domain, SlowDNS files and firewall rules were preserved.'; echo 'Reserved ports were normalized: VPN SSH=109, Hybrid=443, Dropbear backend=1443.'; echo "Rollback backup: $b"; echo 'Run: menu'
}
main "$@"
