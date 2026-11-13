#!/usr/bin/env python3
N4_VERSION = "2026.11.13-r11"

import datetime
import html
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

BASE = Path("/etc/n4vpn/shares")
CONF = Path("/etc/n4vpn/n4.conf")


def read_conf():
    out = {}
    try:
        for line in CONF.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


def load_token(token):
    if not token or any(
        c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        for c in token
    ):
        return None, "invalid"

    path = BASE / f"{token}.json"

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None, "missing"
    except Exception:
        return None, "unreadable"

    try:
        exp = int(data.get("expires_epoch", 0))
    except Exception:
        exp = 0

    # Expired token: the page STILL renders (status/balance checkable).
    # The account is locked server-side, so the config cannot connect, but
    # the user must still be able to open the link and see Expired / GB
    # limit reached + balance. Only truly unknown tokens are invalid.
    # (Changed 2026-11-13 — previously the file was deleted here and the
    # link returned 410.)
    if exp <= int(time.time()):
        return data, "expired"

    return data, "ok"


def remaining_info(username):
    """Live balance, read fresh on EVERY request (so pull-to-refresh works).
    Returns None if this account has no GB record (legacy account).
    Share server runs as n4share, so it cannot read /etc/shadow;
    lock status is therefore not shown here (Bot detail shows it)."""
    if not username:
        return None
    try:
        rec = {}
        for line in Path(f"/etc/n4vpn/accounts/{username}").read_text(encoding="utf-8").splitlines():
            if "=" in line:
                k, v = line.strip().split("=", 1)
                rec[k] = v
    except OSError:
        return None
    try:
        gb = int(rec.get("GB_LIMIT", "0") or 0)
    except ValueError:
        gb = 0
    try:
        used = int(rec.get("USED_BYTES", "0") or 0)
    except ValueError:
        used = 0
    used_gb = used / (1024 ** 3)
    expiry = rec.get("EXPIRY", "")
    days_left = None
    if expiry:
        try:
            days_left = (datetime.date.fromisoformat(expiry) - datetime.date.today()).days
        except ValueError:
            days_left = None
    if days_left is not None and days_left < 0:
        status = "Expired"
    elif gb > 0 and used_gb >= gb:
        status = "GB limit reached"
    else:
        status = "Active"
    rem_gb = (gb - used_gb) if gb > 0 else None
    return {
        "status": status,
        "expiry": expiry,
        "days_left": days_left,
        "gb": gb,
        "used_gb": used_gb,
        "used_mb": used / (1024 ** 2),
        # Remaining is clamped at 0 — a user 0.07 GB over the limit sees
        # 0.00 GB, never a negative number.
        "rem_gb": max(0.0, rem_gb) if rem_gb is not None else None,
        "percent_used": (used_gb / gb * 100.0) if gb > 0 else None,
    }


def esc(value):

    return html.escape(str(value or ""))


class Handler(BaseHTTPRequestHandler):
    server_version = "N4Share/2.1"

    def log_message(self, fmt, *args):
        return

    def send_bytes(self, code, body, ctype="text/html; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode()

        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parts = urlparse(self.path).path.strip("/").split("/")

        if len(parts) != 2 or parts[0] != "s":
            return self.send_bytes(
                404,
                "Not found",
                "text/plain; charset=utf-8",
            )

        data, state = load_token(parts[1])

        if not data:
            msg = (
                "This share link has expired."
                if state == "expired"
                else "This share link is invalid or revoked."
            )
            return self.send_bytes(
                410,
                msg,
                "text/plain; charset=utf-8",
            )

        cfg = read_conf()

        def pick(*keys):
            for key in keys:
                val = data.get(key)
                if val not in (None, "", "disabled"):
                    return str(val).strip()
            for key in keys:
                val = cfg.get(key)
                if val not in (None, "", "disabled"):
                    return str(val).strip()
            return ""

        def public_key():
            val = pick("slowdns_public_key", "slowdns_pubkey", "public_key",
                       "SLOWDNS_PUBLIC_KEY", "SLOWDNS_PUBKEY")
            if val:
                return val
            for p in (Path("/etc/n4vpn/server.pub"),
                      Path("/etc/slowdns/server.pub"),
                      Path("/root/server.pub")):
                try:
                    val = p.read_text(encoding="utf-8", errors="ignore").strip()
                    if val:
                        return val
                except OSError:
                    pass
            return ""

        host = pick("host", "HOST_DOMAIN", "SERVER_IP")
        username = pick("username")
        password = pick("password")
        ns = pick("slowdns_ns", "SLOWDNS_NS")
        pubkey = public_key()

        ssh_port = pick("ssh_port", "VPN_SSH_PORT") or "109"
        ws_ports = pick("ws_ports", "WS_PORTS") or "80,143,442,8080"
        hybrid_port = pick("hybrid_port", "HYBRID_PORT") or "443"
        dropbear_ports = pick("dropbear_ports", "DROPBEAR_PORTS") or hybrid_port

        quick = []
        for label, key, val in (
            ("Host / IP", "host", host),
            ("Username", "username", username),
            ("Password", "password", password),
            ("SlowDNS NS", "slowdns_ns", ns),
            ("Public Key", "public_key", pubkey),
        ):
            if val:
                quick.append(
                    f'<div class="q"><div><span>{esc(label)}</span>'
                    f'<code id="{key}">{esc(val)}</code></div>'
                    f'<button class="copy" onclick="cp(\'{key}\',this)">Copy</button></div>'
                )

        details = "".join(
            f'<div class="d"><span>{esc(label)}</span><b>{esc(val)}</b></div>'
            for label, val in (
                ("VPN SSH", ssh_port),
                ("WebSocket", ws_ports),
                ("Hybrid / Dropbear", hybrid_port),
                ("Dropbear Ports", dropbear_ports),
            ) if val
        )

        rem = remaining_info(username)
        updated_txt = time.strftime("%Y-%m-%d %H:%M:%S")
        if rem is None:
            status_key = "active"
            status_badge = '<span class="s-badge s-active">● Active — သုံးလို့ရပါတယ်</span>'
            status_note = ""
            status_meta = '<span class="active">● Active</span>'
            status_section = (
                '<section class="sec"><div class="st">ACCOUNT STATUS</div>'
                + status_badge
                + '<div class="d"><span>Balance</span><b>Not available for this account</b></div>'
                + f'<div class="meta"><span>Last updated: {esc(updated_txt)} (server time)</span></div></section>'
            )
            dim_open, dim_close = "", ""
        else:
            if rem["days_left"] is None:
                days_txt = "-"
            elif rem["days_left"] < 0:
                days_txt = f"Expired {-rem['days_left']} days ago"
            elif rem["days_left"] == 0:
                days_txt = "Last day"
            else:
                days_txt = f"{rem['days_left']} days left"
            rem_gb_txt = f"{rem['rem_gb']:.2f} GB" if rem["rem_gb"] is not None else "Unlimited"
            gb_txt = f"{rem['gb']} GB" if rem["gb"] > 0 else "Unlimited"
            expiry_txt = rem["expiry"] or "-"
            if rem["status"] == "Expired":
                status_key = "expired"
                status_badge = '<span class="s-badge s-expired">● သက်တမ်း ကုန်သွားပြီ — Expired</span>'
                status_note = "VPN ချိတ်လို့မရတော့ပါ — Renew လုပ်ပါ။ ဒီ Link ကနေ Balance ပြန်စစ်လို့ရပါတယ်။"
                status_meta = '<span class="expired">● Expired</span>'
            elif rem["status"] == "GB limit reached":
                status_key = "gb"
                status_badge = '<span class="s-badge s-gb">● GB ကုန်သွားပြီ — GB Limit Reached</span>'
                status_note = "VPN ချိတ်လို့မရတော့ပါ — Renew လုပ်ပါ။ ဒီ Link ကနေ Balance ပြန်စစ်လို့ရပါတယ်။"
                status_meta = '<span class="gb">● GB Limit Reached</span>'
            else:
                status_key = "active"
                status_badge = '<span class="s-badge s-active">● Active — သုံးလို့ရပါတယ်</span>'
                status_note = ""
                status_meta = '<span class="active">● Active</span>'
            if rem["percent_used"] is None:
                bar = '<div class="bar-note">GB Limit: Unlimited</div>'
            else:
                pct = rem["percent_used"]
                bar = (
                    f'<div class="bar"><div class="barfill {"bar-gb" if pct >= 100 else "bar-ok"}" '
                    f'style="width:{min(pct, 100.0):.1f}%"></div></div>'
                    f'<div class="bar-label"><span>Used {rem["used_gb"]:.2f} GB / {gb_txt}</span>'
                    f'<span>{pct:.0f}%</span></div>'
                )
            bignums = "".join(
                f'<div class="big"><span>{esc(label)}</span><b>{esc(val)}</b></div>'
                for label, val in (
                    ("Used", f"{rem['used_gb']:.2f} GB"),
                    ("Remaining", rem_gb_txt),
                    ("Days Left", days_txt),
                    ("Expiry Date", expiry_txt),
                )
            )
            note_html = f'<div class="note">{esc(status_note)}</div>' if status_note else ""
            status_section = (
                '<section class="sec"><div class="st">ACCOUNT STATUS — အခြေအနေ</div>'
                + status_badge + note_html + bar
                + f'<div class="bignums">{bignums}</div>'
                + '<button class="refresh" onclick="location.reload()">↻ Refresh — အသစ်ပြန်ဖတ်</button>'
                + f'<div class="meta"><span>Last updated: {esc(updated_txt)} (server time, re-read on every refresh)</span></div></section>'
            )
            if status_key == "active":
                dim_open, dim_close = "", ""
            else:
                # Config stays visible (server/port info) but dimmed, with a
                # clear note that it cannot connect until renewed.
                dim_open = (
                    '<div class="dim-note">ဒီ Config နဲ့ ချိတ်လို့မရတော့ပါ — Renew လုပ်ပါ</div>'
                    '<div class="dimmed">'
                )
                dim_close = "</div>"

        default_payload = "GET / HTTP/1.1[crlf]Host: [host][crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]"
        mec_payload = "PUT [host_port] [protocol][crlf]Host: www.mectel.com.mm[crlf][crlf]"

        body = f"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex,nofollow,noarchive">
<meta name="theme-color" content="#080a0f">
<title>N4 VPN</title>
<style>
:root{{color-scheme:dark;--bg:#07090d;--card:#0d1117;--line:#202833;--muted:#8b96a5;--green:#7de5a0;--red:#ff304f;--orange:#ffb454;--blue:#8ec8ff}}
*{{box-sizing:border-box;-webkit-tap-highlight-color:transparent}}
html,body{{margin:0;min-height:100%;background:radial-gradient(circle at top,rgba(255,48,79,.08),transparent 30%),var(--bg);color:#f4f6f8;font-family:system-ui,-apple-system,"Segoe UI",sans-serif}}
body{{padding:max(10px,env(safe-area-inset-top)) 10px max(12px,env(safe-area-inset-bottom))}}
.wrap{{max-width:560px;margin:auto}}.card{{background:rgba(13,17,23,.97);border:1px solid var(--line);border-radius:20px;overflow:hidden;box-shadow:0 18px 45px #0007}}
.head{{padding:13px 14px 11px;border-bottom:1px solid var(--line)}}.brand{{display:flex;justify-content:space-between;align-items:center;gap:10px}}.bl{{display:flex;align-items:center;gap:9px}}
.logo{{width:36px;height:36px;border-radius:11px;display:grid;place-items:center;background:linear-gradient(145deg,#ff405c,#b50022);font-weight:900;box-shadow:0 7px 20px rgba(255,48,79,.22)}}
.name strong{{display:block;font-size:16px}}.name small{{color:var(--muted);font-size:10px}}.badge{{font-size:9px;font-weight:850;letter-spacing:.8px;color:#ff8da0;border:1px solid rgba(255,48,79,.28);background:rgba(255,48,79,.08);padding:5px 8px;border-radius:999px}}
.meta{{margin-top:9px;display:flex;justify-content:space-between;color:var(--muted);font-size:10px}}.active{{color:var(--green)}}
.sec{{padding:10px 12px;border-bottom:1px solid var(--line)}}.st{{font-size:9px;font-weight:850;letter-spacing:1px;color:#aab4c0;margin-bottom:7px}}
.quick{{display:grid;grid-template-columns:1fr 1fr;gap:6px}}.q{{min-width:0;display:flex;align-items:center;gap:6px;background:#090d12;border:1px solid #202a35;border-radius:10px;padding:7px 8px}}.q>div{{min-width:0;flex:1}}.q span{{display:block;color:var(--muted);font-size:8px;margin-bottom:3px}}.q code{{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--green);font:11px ui-monospace,monospace}}
.copy{{border:0;border-radius:7px;padding:6px 7px;background:#171e27;color:#e4eaf0;font-size:8px;font-weight:850}}.copy.ok{{color:var(--green);background:rgba(125,229,160,.12)}}
.details{{display:grid;grid-template-columns:1fr 1fr;gap:6px}}.d{{background:#090d12;border:1px solid #202a35;border-radius:10px;padding:7px 8px}}.d span{{display:block;color:var(--muted);font-size:8px;margin-bottom:3px}}.d b{{font-size:10px;font-weight:750;word-break:break-word}}
.payloads{{display:grid;grid-template-columns:1fr 1fr;gap:6px}}.p{{min-width:0;background:#090d12;border:1px solid #202a35;border-radius:10px;padding:7px 8px}}.pt{{display:flex;justify-content:space-between;align-items:center;margin-bottom:5px}}.pt span{{font-size:9px;font-weight:850}}.p code{{display:block;height:43px;overflow:auto;word-break:break-word;white-space:normal;color:var(--blue);font:8.5px/1.35 ui-monospace,monospace;scrollbar-width:none}}.p code::-webkit-scrollbar{{display:none}}
.foot{{padding:8px 12px 10px;display:flex;justify-content:space-between;gap:8px;color:#65717f;font-size:8px}}
.s-badge{{display:inline-block;font-size:15px;font-weight:850;padding:9px 12px;border-radius:999px;margin:2px 0 8px}}
.s-active{{color:#0d3d1e;background:rgba(125,229,160,.18);border:1px solid rgba(125,229,160,.45)}}
.s-gb{{color:#3d2700;background:rgba(255,180,84,.18);border:1px solid rgba(255,180,84,.5)}}
.s-expired{{color:#ffd7dc;background:rgba(255,48,79,.2);border:1px solid rgba(255,48,79,.5)}}
.note{{font-size:11px;color:#c8d0da;margin:0 0 9px;line-height:1.5}}
.bar{{height:12px;border-radius:999px;background:#171e27;border:1px solid #202a35;overflow:hidden}}
.barfill{{height:100%;border-radius:999px}}.bar-ok{{background:linear-gradient(90deg,#2fbf71,#7de5a0)}}.bar-gb{{background:linear-gradient(90deg,#ff8a00,#ffb454)}}
.bar-label{{display:flex;justify-content:space-between;color:var(--muted);font-size:10px;margin:5px 1px 9px}}
.bar-note{{color:var(--muted);font-size:10px;margin:0 0 9px}}
.bignums{{display:grid;grid-template-columns:1fr 1fr;gap:6px}}
.big{{background:#090d12;border:1px solid #202a35;border-radius:12px;padding:10px}}
.big span{{display:block;color:var(--muted);font-size:9px;margin-bottom:4px}}
.big b{{font-size:17px;font-weight:800}}
.refresh{{width:100%;border:0;border-radius:10px;padding:10px;background:#171e27;color:#e4eaf0;font-size:12px;font-weight:800;margin-top:9px;cursor:pointer}}
.dim-note{{margin:10px 12px 0;padding:9px 10px;border-radius:10px;background:rgba(255,48,79,.12);border:1px solid rgba(255,48,79,.35);color:#ffb3bd;font-size:11px;font-weight:800;text-align:center}}
.dimmed{{opacity:.45;filter:grayscale(.6)}}
.expired{{color:var(--red)}}.gb{{color:var(--orange)}}
@media(max-width:370px){{.quick{{grid-template-columns:1fr}}.payloads{{grid-template-columns:1fr}}}}
</style></head><body><div class="wrap"><section class="card">
<header class="head"><div class="brand"><div class="bl"><div class="logo">N4</div><div class="name"><strong>N4 VPN</strong><small>Connection Details</small></div></div><div class="badge">PRIVATE</div></div><div class="meta">{status_meta}<span>Expires {esc(data.get("expires_date",""))}</span></div></header>
{status_section}
{dim_open}<section class="sec"><div class="st">QUICK COPY</div><div class="quick">{''.join(quick)}</div></section>
<section class="sec"><div class="st">SERVICE DETAILS</div><div class="details">{details}</div></section>
<section class="sec"><div class="st">PAYLOADS</div><div class="payloads">
<div class="p"><div class="pt"><span>DEFAULT</span><button class="copy" onclick="cp('default_payload',this)">Copy</button></div><code id="default_payload">{esc(default_payload)}</code></div>
<div class="p"><div class="pt"><span>MEC</span><button class="copy" onclick="cp('mec_payload',this)">Copy</button></div><code id="mec_payload">{esc(mec_payload)}</code></div>
</div></section>{dim_close}
<footer class="foot"><span>N4 NETWORK • {esc(N4_VERSION)}</span><span>Link stays checkable after expiry — VPN stays locked until renewed</span></footer>
</section></div>
<script>
async function cp(id,b){{const e=document.getElementById(id),t=e.textContent;try{{await navigator.clipboard.writeText(t)}}catch(_){{const a=document.createElement("textarea");a.value=t;a.style.position="fixed";a.style.opacity="0";document.body.appendChild(a);a.select();document.execCommand("copy");a.remove()}}const o=b.textContent;b.textContent="OK";b.classList.add("ok");setTimeout(()=>{{b.textContent=o;b.classList.remove("ok")}},850)}}
</script></body></html>"""

        self.send_bytes(200, body)


def main():
    BASE.mkdir(parents=True, exist_ok=True)

    cfg = read_conf()

    try:
        port = int(cfg.get("SHARE_PORT", "8880"))
    except ValueError:
        port = 8880

    if not 1 <= port <= 65535:
        port = 8880

    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
