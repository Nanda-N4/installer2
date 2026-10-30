#!/usr/bin/env python3
N4_VERSION = "2026.09.24-r10"

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

    if exp <= int(time.time()):
        try:
            path.unlink()
        except OSError:
            pass
        return None, "expired"

    return data, "ok"


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
:root{{color-scheme:dark;--bg:#07090d;--card:#0d1117;--line:#202833;--muted:#8b96a5;--green:#7de5a0;--red:#ff304f;--blue:#8ec8ff}}
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
@media(max-width:370px){{.quick{{grid-template-columns:1fr}}.payloads{{grid-template-columns:1fr}}}}
</style></head><body><div class="wrap"><section class="card">
<header class="head"><div class="brand"><div class="bl"><div class="logo">N4</div><div class="name"><strong>N4 VPN</strong><small>Connection Details</small></div></div><div class="badge">PRIVATE</div></div><div class="meta"><span class="active">● Active</span><span>Expires {esc(data.get("expires_date",""))}</span></div></header>
<section class="sec"><div class="st">QUICK COPY</div><div class="quick">{''.join(quick)}</div></section>
<section class="sec"><div class="st">SERVICE DETAILS</div><div class="details">{details}</div></section>
<section class="sec"><div class="st">PAYLOADS</div><div class="payloads">
<div class="p"><div class="pt"><span>DEFAULT</span><button class="copy" onclick="cp('default_payload',this)">Copy</button></div><code id="default_payload">{esc(default_payload)}</code></div>
<div class="p"><div class="pt"><span>MEC</span><button class="copy" onclick="cp('mec_payload',this)">Copy</button></div><code id="mec_payload">{esc(mec_payload)}</code></div>
</div></section>
<footer class="foot"><span>N4 NETWORK • {esc(N4_VERSION)}</span><span>Auto expires with account</span></footer>
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
