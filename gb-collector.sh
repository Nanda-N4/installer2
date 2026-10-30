#!/usr/bin/env bash
# gb-collector v2 - byte collector for GB Limit (connmark method).
#
# WHY v2: OUTPUT --uid-owner alone was PROVEN unfit for SSH WS on
# 2026-10-30 (n420h5, uid 1001, download to ~100 MB, exit IP proven
# 45.32.105.188 Vultr): between two live runs total server OUTPUT grew
# +454,148,118 bytes, but the uid-owner rule grew only +1,430,537 bytes
# (0.31%, avg 77 bytes/packet = control packets only). Download-heavy
# WS traffic leaves the VPS via root ws-proxy (ws-proxy -> client),
# so uid-owner OUTPUT misses the bulk. See GB-DIAGNOSIS-2026-10-30.md.
#
# HOW v2 works (iptables only, no new dependency):
#  1. Marking (mangle OUTPUT, NEW connections only): when a per-user
#     sshd process opens a destination connection, its first OUTPUT
#     packet is owned by that UID, so we set the connection's conntrack
#     mark to the UID: -m conntrack --ctstate NEW -m owner --uid-owner
#     <uid> -j CONNMARK --set-mark <uid>
#  2. Counting (filter INPUT + OUTPUT): every packet of that connection,
#     in BOTH directions, carries the conntrack mark, even though
#     owner-match does not work on INPUT. So we count:
#       N4CONN   (OUTPUT)  -m connmark --mark <uid>
#       N4CONNIN (INPUT)   -m connmark --mark <uid>
#     Total per user = INPUT bytes + OUTPUT bytes of its destination
#     connections = upload + download, counted once per direction.
#     The phone<->VPS SSH/WS leg is deliberately NOT counted, otherwise
#     the same bytes would be counted twice (once as destination
#     traffic, once as SSH channel traffic).
#  3. Delta only: state file accounts/.collector-state-conn, so a
#     reboot / re-run / counter reset never double-counts.
#
# The old N4ACCT uid-owner OUTPUT chain is KEPT for comparison logging
# only. It is NOT added to USED_BYTES (that would double-count the
# small upload fraction it does see).
#
# FAIL-OPEN by design: if iptables-save is missing, or no connmark
# rules parse, or marking fails, USED_BYTES is left unchanged and the
# run exits 0 with a log line. A collector failure must NEVER lock
# users, and must NEVER pretend to enforce a limit it is not counting.
set -u
ACCOUNTS_DIR=/etc/n4vpn/accounts
STATE_FILE=/etc/n4vpn/accounts/.collector-state-conn
LOG=/var/log/n4vpn/gb-collector.log
log(){ mkdir -p /var/log/n4vpn 2>/dev/null || true; echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null || true; }

ensure_chains(){
  command -v iptables >/dev/null 2>&1 || return 0
  iptables -N N4CONN 2>/dev/null || true
  iptables -N N4CONNIN 2>/dev/null || true
  iptables -N N4ACCT 2>/dev/null || true
  iptables -C OUTPUT -j N4CONN 2>/dev/null || iptables -I OUTPUT 1 -j N4CONN 2>/dev/null || true
  iptables -C OUTPUT -j N4ACCT 2>/dev/null || iptables -I OUTPUT 2 -j N4ACCT 2>/dev/null || true
  iptables -C INPUT -j N4CONNIN 2>/dev/null || iptables -I INPUT 1 -j N4CONNIN 2>/dev/null || true
  while IFS=: read -r u _ uid _ _ _ _; do
    ((uid>=1000)) || continue; [[ $u == nobody ]] && continue
    [[ -f $ACCOUNTS_DIR/$u ]] || continue
    # Marking: NEW destination connections opened by this UID.
    iptables -t mangle -C OUTPUT -m conntrack --ctstate NEW -m owner --uid-owner "$uid" -j CONNMARK --set-mark "$uid" 2>/dev/null || iptables -t mangle -A OUTPUT -m conntrack --ctstate NEW -m owner --uid-owner "$uid" -j CONNMARK --set-mark "$uid" 2>/dev/null || log "connmark marking failed for $u uid=$uid"
    # Counting rules (both directions).
    iptables-save -c 2>/dev/null | grep -q -- "-A N4CONN .*--mark $uid " || iptables -A N4CONN -m connmark --mark "$uid" -j RETURN 2>/dev/null || true
    iptables-save -c 2>/dev/null | grep -q -- "-A N4CONNIN .*--mark $uid " || iptables -A N4CONNIN -m connmark --mark "$uid" -j RETURN 2>/dev/null || true
    # Legacy owner rule (comparison only, kept from v1).
    iptables-save -c 2>/dev/null | grep -q -- "--uid-owner $uid " || iptables -A N4ACCT -m owner --uid-owner "$uid" -j RETURN 2>/dev/null || true
  done </etc/passwd
}

collect(){
  [[ -d $ACCOUNTS_DIR ]] || exit 0
  ensure_chains
  command -v iptables-save >/dev/null 2>&1 || { log "iptables-save missing, fail-open, no change"; exit 0; }
  python3 - "$STATE_FILE" "$ACCOUNTS_DIR" "$LOG" <<'PY'
import re, subprocess, sys, os
state_path, accounts, log_path = sys.argv[1], sys.argv[2], sys.argv[3]
def logline(msg):
    try:
        with open(log_path, "a", encoding="utf-8") as lf:
            import datetime
            lf.write(f"{datetime.datetime.now().strftime('%F %T')} {msg}\n")
    except OSError:
        pass
try:
    out = subprocess.run(["iptables-save", "-c"], capture_output=True, text=True, timeout=30).stdout
except Exception:
    sys.exit(0)
cur = {}
old_owner = {}
for line in out.splitlines():
    m = re.match(r"\[(\d+):(\d+)\]\s+-A N4CONN\b.*--mark\s+(\d+)\b", line)
    if m:
        cur[int(m.group(3))] = cur.get(int(m.group(3)), 0) + int(m.group(2))
        continue
    m = re.match(r"\[(\d+):(\d+)\]\s+-A N4CONNIN\b.*--mark\s+(\d+)\b", line)
    if m:
        cur[int(m.group(3))] = cur.get(int(m.group(3)), 0) + int(m.group(2))
        continue
    m = re.match(r"\[(\d+):(\d+)\]\s+-A N4ACCT\b.*--uid-owner\s+(\d+)\b", line)
    if m:
        old_owner[int(m.group(3))] = int(m.group(2))
if not cur:
    # No connmark data at all: fail-open, do not touch USED_BYTES.
    logline("connmark no rules parsed, fail-open, no change")
    sys.exit(2)
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
    # Comparison line for VPS verification (written to the collector log).
    logline(f"CONN uid={uid} user={user} total={newbytes} delta={delta} owner_old={old_owner.get(uid, 0)}")
with open(state_path, "w", encoding="utf-8") as f:
    for uid, b in sorted(cur.items()):
        f.write(f"{uid}:{b}\n")
PY
  rc=$?
  if [[ $rc -eq 2 ]]; then log "collector conn no-data, fail-open, no change"; exit 0; fi
  if [[ $rc -ne 0 ]]; then log "collector python failed, fail-open, no change"; exit 0; fi
  log "collector conn ok"
}
collect
