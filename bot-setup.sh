#!/usr/bin/env bash
# bot-setup.sh - TG BOT setup, called from menu [8] TG BOT.
# Flow (owner's model): menu -> 8 -> Enter -> prompt Bot Token,
# prompt TG User ID -> write bot.conf (600) -> create n4-bot.service
# -> enable + start -> bot runs ALWAYS (Restart=always, survives
# reboot via WantedBy=multi-user.target). Token and ID are NEVER
# in the repo, never logged, never printed back.
set -u
BOT_CONF=/etc/n4vpn/bot.conf

bot_setup() {
  read -r -s -p 'Telegram Bot Token (from @BotFather, not stored in repo): ' token; echo
  [[ -n $token ]] || { echo 'Token required.' >&2; return 1; }
  read -r -p 'Telegram User ID (only this ID may use the bot): ' tgid
  [[ $tgid =~ ^[0-9]+$ ]] || { echo 'TG User ID must be numbers only.' >&2; return 1; }
  mkdir -p /etc/n4vpn
  printf 'BOT_TOKEN=%s\nOWNER_TG_ID=%s\n' "$token" "$tgid" >"$BOT_CONF"
  chmod 600 "$BOT_CONF"
  cat >/etc/systemd/system/n4-bot.service <<'EOF'
[Unit]
Description=N4 Telegram Bot (TG BOT)
StartLimitIntervalSec=0
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/bot.py --poll
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now n4-bot.service
  if systemctl is-active --quiet n4-bot.service; then
    echo 'Bot setup done. Bot is RUNNING and will always run (auto-restart + auto-start on reboot).'
  else
    echo 'Bot service started but is NOT active - check: journalctl -u n4-bot -n 50' >&2; return 1
  fi
}

bot_setup
