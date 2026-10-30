#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_VERSION="2026.09.24-r10.1-migratefix"
export DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1
REPO_RAW="https://raw.githubusercontent.com/Nanda-N4/installer2/main"
# DNS files (SlowDNS) come from installer1 (original repo) on purpose:
# dnstt-server is a binary that cannot be snapshot-pushed, and the
# original keypair already works as-is. Only these 3 files use installer1;
# every other file still comes from installer2.
SLOWDNS_RAW="https://raw.githubusercontent.com/Nanda-N4/installer/main"
N4_DIR=/etc/n4vpn; CONF=$N4_DIR/n4.conf
C1='\033[38;5;51m'; C2='\033[38;5;48m'; C3='\033[38;5;220m'; C4='\033[38;5;231m'; C5='\033[38;5;244m'; CR='\033[38;5;196m'; B='\033[1m'; N='\033[0m'
trap 'rc=$?; echo -e "${CR}[!] Failed at line $LINENO (exit $rc): ${BASH_COMMAND}${N}"' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root'; exit 1; }

fetch_repo(){ local f=$1 d=$2; curl -fL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 90 -H 'Cache-Control: no-cache' "${REPO_RAW}/${f}?cb=$(date +%s%N)" -o "$d"; }
fetch_slowdns(){ local f=$1 d=$2; curl -fL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 90 -H 'Cache-Control: no-cache' "${SLOWDNS_RAW}/${f}?cb=$(date +%s%N)" -o "$d"; }
logo(){ clear; echo -e "${C1}╭────────────────────────────────────────────────────────────╮${N}"; echo -e "${C1}│${N} ${B}${C4}N4 VPN • CORE INSTALLER 2026 • r10.1${N}                          ${C1}│${N}"; echo -e "${C1}│${N} ${C5}SSH • WS • Hybrid Dropbear • SlowDNS • Auto Recovery${N}      ${C1}│${N}"; echo -e "${C1}╰────────────────────────────────────────────────────────────╯${N}"; }
step(){ echo -e "\n${C3}${B}[$1]${N} ${C4}$2${N}"; }
valid_port(){ [[ ${1:-} =~ ^[0-9]+$ ]] && ((1<=10#$1 && 10#$1<=65535)); }

load_conf(){
 VPN_SSH_PORT=109; WS_PORTS='80'; DROPBEAR_PORTS=''; HYBRID_PORT=443; DROPBEAR_INTERNAL_PORT=1443
 DEVICE_LIMIT_DEFAULT=1; WS_MAX_CLIENTS=2048; WS_IDLE_TIMEOUT=180; HOST_DOMAIN=''; SLOWDNS_ENABLED=0; NS_DOMAIN=''; PUBLIC_IPV4=''; SHARE_PORT=8880
 AUTO_REBOOT=1; HEALTH_FAIL_THRESHOLD=5; HEALTH_REBOOT_COOLDOWN=21600
 [[ -f $CONF ]] && source "$CONF" || true
 [[ -z $HOST_DOMAIN && -f /etc/vps-domain.txt ]] && HOST_DOMAIN=$(cat /etc/vps-domain.txt) || true
 return 0
}
save_conf(){
 mkdir -p "$N4_DIR/device-limits" "$N4_DIR/shares" /var/log/n4vpn /var/lib/n4vpn-health
 cat >"$CONF" <<EOF
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
 chmod 600 "$CONF"; echo "$HOST_DOMAIN" >/etc/vps-domain.txt
}
protect_22(){ iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT 2>/dev/null || true; command -v ufw >/dev/null 2>&1 && ufw allow 22/tcp >/dev/null 2>&1 || true; }
allow_port(){ local p=$1 proto=${2:-tcp}; valid_port "$p" || return 0; iptables -C INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || iptables -A INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || true; command -v ufw >/dev/null 2>&1 && ufw allow "$p/$proto" >/dev/null 2>&1 || true; }

write_banner(){ cat >/etc/issue.net <<'EOF'
══════════════════════════════════════
       ★ N4 VPN PREMIUM SERVER ★
══════════════════════════════════════
● STATUS : CONNECTED & ENCRYPTED
● POLICY : NO SPAM / FRAUD / ABUSE
══════════════════════════════════════
Telegram : https://t.me/n4vpn
Support  : https://t.me/n4nd404
══════════════════════════════════════
EOF
}
write_vpn_ssh(){ write_banner; cat >/etc/ssh/sshd_vpn_config <<EOF
Port $VPN_SSH_PORT
ListenAddress 0.0.0.0
ListenAddress ::
PidFile /run/sshd_vpn.pid
Protocol 2
UsePAM yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
AllowTcpForwarding yes
GatewayPorts yes
PermitTunnel yes
X11Forwarding no
PrintMotd no
ClientAliveInterval 60
ClientAliveCountMax 3
LoginGraceTime 30
MaxStartups 100:30:500
MaxSessions 32
Banner /etc/issue.net
EOF
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
}
write_dropbear(){ local args=" -p 127.0.0.1:$DROPBEAR_INTERNAL_PORT" p; IFS=, read -ra a<<<"$DROPBEAR_PORTS"; for p in "${a[@]}"; do [[ $p == "$HYBRID_PORT" ]] && continue; args+=" -p $p"; done; cat >/etc/default/dropbear <<EOF
NO_START=0
DROPBEAR_PORT=0
DROPBEAR_EXTRA_ARGS="$args -w -g"
DROPBEAR_BANNER="/etc/issue.net"
EOF
}
write_ws_unit(){ cat >/etc/systemd/system/ws-proxy.service <<'EOF'
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
}
write_slowdns(){
 if [[ $SLOWDNS_ENABLED -eq 1 ]]; then
  mkdir -p /etc/slowdns
  [[ -x /etc/slowdns/dnstt-server ]] || fetch_slowdns dnstt-server /etc/slowdns/dnstt-server
  [[ -s /etc/slowdns/server.key ]] || fetch_slowdns server.key /etc/slowdns/server.key
  [[ -s /etc/slowdns/server.pub ]] || fetch_slowdns server.pub /etc/slowdns/server.pub
  chmod 755 /etc/slowdns/dnstt-server; chmod 600 /etc/slowdns/server.key; echo "$NS_DOMAIN" >/etc/slowdns/nsdomain.txt
  if [[ -f /etc/systemd/resolved.conf ]]; then grep -q '^DNSStubListener=' /etc/systemd/resolved.conf && sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf || echo 'DNSStubListener=no' >>/etc/systemd/resolved.conf; systemctl restart systemd-resolved 2>/dev/null || true; fi
  cat >/etc/systemd/system/slowdns.service <<EOF
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
}
write_share(){
 mkdir -p "$N4_DIR/shares"; chmod 750 "$N4_DIR/shares"; id -u n4share >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin n4share
 fetch_repo share-server.py /usr/local/bin/n4-share-server.py; chmod 755 /usr/local/bin/n4-share-server.py; chown -R n4share:n4share "$N4_DIR/shares"
 find "$N4_DIR/shares" -type f -name '*.json' -exec chown n4share:n4share {} \; -exec chmod 640 {} \; 2>/dev/null || true
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
}
write_health(){
 cat >/usr/local/sbin/n4-healthcheck <<'EOF'
#!/usr/bin/env bash
set -u
CONF=/etc/n4vpn/n4.conf; STATE=/var/lib/n4vpn-health; LOG=/var/log/n4vpn/health.log
mkdir -p "$STATE" /var/log/n4vpn; source "$CONF" 2>/dev/null || exit 0
now=$(date +%s); failed=0
log(){ echo "$(date '+%F %T') $*" >>"$LOG"; }
port_ok(){ timeout 2 bash -c "</dev/tcp/127.0.0.1/$1" >/dev/null 2>&1; }
heal(){ local svc=$1 port=${2:-}; if ! systemctl is-active --quiet "$svc" || { [[ -n $port ]] && ! port_ok "$port"; }; then failed=1; log "FAIL $svc port=${port:-n/a}; restart"; systemctl restart "$svc" >/dev/null 2>&1 || true; sleep 2; fi; }
heal vpn-ssh "${VPN_SSH_PORT:-109}"
heal dropbear "${DROPBEAR_INTERNAL_PORT:-1443}"
heal ws-proxy "${HYBRID_PORT:-443}"
if [[ ${SLOWDNS_ENABLED:-0} == 1 ]]; then systemctl is-active --quiet slowdns || { failed=1; log 'FAIL slowdns; restart'; systemctl restart slowdns >/dev/null 2>&1 || true; }; fi
heal n4-share "${SHARE_PORT:-8880}"
countfile="$STATE/fail-count"; count=$(cat "$countfile" 2>/dev/null || echo 0)
if (( failed )); then count=$((count+1)); else count=0; fi
echo "$count" >"$countfile"
threshold=${HEALTH_FAIL_THRESHOLD:-5}; cooldown=${HEALTH_REBOOT_COOLDOWN:-21600}
if [[ ${AUTO_REBOOT:-1} == 1 ]] && (( count >= threshold )); then
 uptime_s=$(cut -d. -f1 /proc/uptime); last=$(cat "$STATE/last-reboot-request" 2>/dev/null || echo 0)
 if (( uptime_s > 900 && now-last > cooldown )); then
  log "CORE unhealthy for $count checks; controlled reboot requested"
  echo "$now" >"$STATE/last-reboot-request"; sync; /sbin/shutdown -r +1 'N4 auto recovery: repeated core service failures' >/dev/null 2>&1 || true
 fi
fi
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
 systemctl disable --now vpn-watchdog.service 2>/dev/null || true; rm -f /etc/systemd/system/vpn-watchdog.service /usr/local/bin/vpn-watchdog.sh
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
Description=N4 GB limit timer (every 1 minute)
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
Persistent=true
[Install]
WantedBy=timers.target
EOF
}
write_auto_menu(){ cat >/etc/profile.d/n4-menu.sh <<'EOF'
if [ "$(id -u 2>/dev/null)" = 0 ] && [ -t 0 ] && [ -t 1 ] && [ -z "${N4_MENU_ACTIVE:-}" ] && [ -x /usr/local/bin/menu ]; then
 case "${TERM:-}" in dumb|'') ;; *) export N4_MENU_ACTIVE=1; /usr/local/bin/menu || true ;; esac
fi
EOF
 chmod 644 /etc/profile.d/n4-menu.sh; }
install_common(){
 apt-get update -y; apt-get install -y openssh-server dropbear python3 curl wget ca-certificates jq bc iproute2 net-tools lsof psmisc dnsutils procps openssl iptables iptables-persistent util-linux
 cat >/etc/security/limits.d/99-n4vpn.conf <<'EOF'
* soft nofile 262144
* hard nofile 262144
root soft nofile 262144
root hard nofile 262144
EOF
 cat >/etc/sysctl.d/99-n4vpn.conf <<'EOF'
fs.file-max = 1048576
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
EOF
 sysctl --system >/dev/null 2>&1 || true; ssh-keygen -A >/dev/null 2>&1 || true
 fetch_repo ws-proxy.py /usr/local/bin/ws-proxy.py; fetch_repo menu.sh /usr/local/bin/menu; fetch_repo update.sh /usr/local/bin/n4-update; fetch_repo gb-limit.sh /usr/local/bin/gb-limit.sh; fetch_repo gb-collector.sh /usr/local/bin/gb-collector.sh; fetch_repo bot-setup.sh /usr/local/bin/bot-setup.sh; fetch_repo bot.py /usr/local/bin/bot.py; fetch_repo n4-create-user.sh /usr/local/bin/n4-create-user.sh
 chmod 755 /usr/local/bin/ws-proxy.py /usr/local/bin/menu /usr/local/bin/n4-update /usr/local/bin/gb-limit.sh /usr/local/bin/gb-collector.sh /usr/local/bin/bot-setup.sh /usr/local/bin/bot.py /usr/local/bin/n4-create-user.sh
 write_vpn_ssh; write_dropbear; write_ws_unit; write_slowdns; write_share; write_health; write_gb_timer; write_auto_menu
}

main(){
 logo; load_conf
 # Existing installations use the migration updater instead of a destructive reinstall.
 if [[ -x /usr/local/bin/menu || -f /etc/ssh/sshd_vpn_config || -d /etc/slowdns || -f /etc/systemd/system/vpn-ssh.service ]]; then
  echo -e "${C3}Existing N4/legacy installation detected.${N}"
  fetch_repo update.sh /tmp/n4-update; chmod +x /tmp/n4-update; exec /tmp/n4-update --migrate
 fi
 step 1/8 'Protecting Admin SSH TCP/22'; protect_22; echo -e "${C2}[✓] Existing firewall rules preserved; TCP/22 explicitly allowed.${N}"
 step 2/8 'Server identity'; ip=$(curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'); [[ -n ${ip:-} ]] || ip=127.0.0.1; PUBLIC_IPV4=$ip
 echo -e "${C5}Default host: ${C4}$ip${N}"; read -r -p ' Use a domain? [y/N]: ' x
 case ${x:-N} in y|Y|yes|YES|Yes) while :; do read -r -p ' Domain: ' x; x=${x#http://}; x=${x#https://}; x=${x%%/*}; [[ -n $x && $x != *' '* ]] && { HOST_DOMAIN=$x; break; }; echo ' Invalid domain.'; done;; *) HOST_DOMAIN=$ip;; esac
 step 3/8 'Default ports'; echo " VPN SSH    : $VPN_SSH_PORT"; echo " WebSocket  : $WS_PORTS"; echo " Hybrid     : $HYBRID_PORT/tcp (Direct Dropbear + Payload)"; echo " Dropbear   : internal $DROPBEAR_INTERNAL_PORT only"
 step 4/8 'SlowDNS'; read -r -p ' Install SlowDNS? [y/N]: ' x; case ${x:-N} in y|Y|yes|YES|Yes) SLOWDNS_ENABLED=1; while :; do read -r -p ' NS domain: ' x; x=${x#http://}; x=${x#https://}; x=${x%%/*}; [[ -n $x && $x != *' '* ]] && { NS_DOMAIN=$x; break; }; echo ' NS domain required.'; done;; *) SLOWDNS_ENABLED=0; NS_DOMAIN='';; esac
 save_conf
 step 5/8 'Installing packages and tuning'; install_common
 step 6/8 'Opening required ports'; protect_22; allow_port "$VPN_SSH_PORT" tcp; IFS=, read -ra a<<<"$WS_PORTS"; for p in "${a[@]}"; do allow_port "$p" tcp; done; IFS=, read -ra a<<<"$DROPBEAR_PORTS"; for p in "${a[@]}"; do allow_port "$p" tcp; done; allow_port "$HYBRID_PORT" tcp; [[ $SLOWDNS_ENABLED -eq 1 ]] && allow_port 53 udp; allow_port "$SHARE_PORT" tcp; iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
 step 7/8 'Starting services'; systemctl daemon-reload; systemctl enable --now vpn-ssh dropbear ws-proxy n4-share n4-healthcheck.timer n4-cleanup.timer n4-gblimit.timer; [[ $SLOWDNS_ENABLED -eq 1 ]] && systemctl enable --now slowdns || true
 step 8/8 'Verification'; /usr/local/sbin/n4-healthcheck || true
 echo; echo -e "${C2}${B}INSTALLATION COMPLETE${N}"; echo "Host: $HOST_DOMAIN"; echo 'Admin SSH: 22 (protected)'; echo "VPN SSH: $VPN_SSH_PORT"; echo "WebSocket: $WS_PORTS"; echo "Hybrid Dropbear/Payload: $HYBRID_PORT"; echo "Share: TCP/$SHARE_PORT"; [[ $SLOWDNS_ENABLED -eq 1 ]] && echo "SlowDNS: UDP/53 • $NS_DOMAIN"; echo 'Auto restart: enabled'; echo 'Controlled auto reboot: enabled after repeated health failures'; echo; echo 'Menu auto-opens on the next interactive root login.'
}
main "$@"
