#!/usr/bin/env bash
# gb-collector - byte collector for GB Limit (fast version).
# Design: iptables owner-match by UID in OUTPUT chain N4ACCT covers
# SSH Direct, SSH WS/Proxy and SlowDNS in one place, because all three
# end in a per-user sshd process. Xray/V2Ray traffic is NOT covered
# (V2Ray/Xray removed from fast version; SSH traffic only.)
# Counters are read with `iptables-save -c`, whose rule format is
# deterministic: [pkts:bytes] -A N4ACCT -m owner --uid-owner <uid> -j RETURN
# Only the DELTA since the last run is added to USED_BYTES, so a
# reboot or re-run never double-counts. State: accounts/.collector-state
# FAIL-OPEN by design: if iptables-save is missing, or no rules parse,
# or any step fails, USED_BYTES is left unchanged and the run exits 0
# with a log line. A collector failure must NEVER lock users.
set -u
ACCOUNTS_DIR=/etc/n4vpn/accounts
STATE_FILE=/etc/n4vpn/accounts/.collector-state
LOG=/var/log/n4vpn/gb-collector.log
log(){ mkdir -p /var/log/n4vpn 2>/dev/null || true; echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null || true; }

ensure_chain(){
  command -v iptables >/dev/null 2>&1 || return 0
  iptables -N N4ACCT 2>/dev/null || true
  iptables -C OUTPUT -j N4ACCT 2>/dev/null || iptables -I OUTPUT 1 -j N4ACCT 2>/dev/null || true
  # Self-healing per-user rules: one RETURN rule per account UID.
  while IFS=: read -r u _ uid _ _ _ _; do
    ((uid>=1000)) || continue; [[ $u == nobody ]] && continue
    [[ -f $ACCOUNTS_DIR/$u ]] || continue
    iptables-save -c 2>/dev/null | grep -q -- "--uid-owner $uid " || iptables -A N4ACCT -m owner --uid-owner "$uid" -j RETURN 2>/dev/null || true
  done </etc/passwd
}

collect(){
  [[ -d $ACCOUNTS_DIR ]] || exit 0
  ensure_chain
  command -v iptables-save >/dev/null 2>&1 || { log "iptables-save missing, fail-open, no change"; exit 0; }
  python3 - "$STATE_FILE" "$ACCOUNTS_DIR" <<'PY'
import re, subprocess, sys, os
state_path, accounts = sys.argv[1], sys.argv[2]
try:
    out = subprocess.run(["iptables-save", "-c"], capture_output=True, text=True, timeout=30).stdout
except Exception:
    sys.exit(0)
cur = {}
for line in out.splitlines():
    m = re.match(r"\[(\d+):(\d+)\]\s+-A N4ACCT\b.*--uid-owner\s+(\d+)\b", line)
    if m:
        cur[int(m.group(3))] = int(m.group(2))
if not cur:
    sys.exit(0)
prev = {}
try:
    for line in open(state_path, encoding="utf-8"):
        if ":" in line:
            k, v = line.strip().split(":", 1); prev[int(k)] = int(v)
except OSError:
    pass
uid2user = {}
try:
    for line in open("/etc/passwd", encoding="utf-8"):
        f = line.split(":")
        if len(f) >= 3:
            uid2user[int(f[2])] = f[0]
except Exception:
    pass
for uid, newbytes in cur.items():
    old = prev.get(uid, 0)
    delta = newbytes - old if newbytes >= old else newbytes
    if delta <= 0:
        continue
    user = uid2user.get(uid)
    if not user:
        continue
    rec = os.path.join(accounts, user)
    if not os.path.isfile(rec):
        continue
    d = {}
    for line in open(rec, encoding="utf-8"):
        if "=" in line:
            k, v = line.strip().split("=", 1); d[k] = v
    try:
        d["USED_BYTES"] = str(int(d.get("USED_BYTES", "0")) + delta)
    except ValueError:
        d["USED_BYTES"] = str(delta)
    with open(rec, "w", encoding="utf-8") as f:
        for k in ("GB_LIMIT", "USED_BYTES", "EXPIRY"):
            if k in d:
                f.write(f"{k}={d[k]}\n")
with open(state_path, "w", encoding="utf-8") as f:
    for uid, b in sorted(cur.items()):
        f.write(f"{uid}:{b}\n")
PY
  log "collector ok"
}
collect
