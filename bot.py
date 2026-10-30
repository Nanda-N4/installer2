#!/usr/bin/env python3
# installer2 bot - Telegram bot for ONE server (reseller's own bot).
# Fast version: GB Limit + Bot Create User, License DEFERRED (not wired).
# Token is read only from /etc/n4vpn/bot.conf (mode 600, bot-setup.sh)
# and is never logged, never printed, never sent anywhere except the
# Telegram Bot API itself. Passwords are never logged or echoed back.
# Closed allowlist only: /start /list /create /renew /delete /usage
# All account work goes through n4-create-user.sh (no shell, list args).
# Usage: bot.py --poll   (Telegram long polling, stdlib urllib only)
#        bot.py /create user pass 30 10   (one command, local test)
import datetime
import json
import re
import secrets
import string
import subprocess
import sys
import time
import urllib.parse
import urllib.request

BOT_CONF = "/etc/n4vpn/bot.conf"
HELPER = "/usr/local/bin/n4-create-user.sh"
ACCOUNTS = "/etc/n4vpn/accounts"
USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{1,31}$")


def load_token():
    try:
        for line in open(BOT_CONF, encoding="utf-8"):
            if line.startswith("BOT_TOKEN="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def load_owner_id():
    try:
        for line in open(BOT_CONF, encoding="utf-8"):
            if line.startswith("OWNER_TG_ID="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def valid_username(u):
    return bool(USERNAME_RE.match(u or ""))


def valid_num(x):
    return bool(re.match(r"^[0-9]+$", x or ""))


def run_helper(args):
    try:
        r = subprocess.run([HELPER] + args, capture_output=True, text=True, timeout=60)
    except Exception as e:
        return f"Helper failed: {e}"
    out = (r.stdout or "").strip()
    err = (r.stderr or "").strip()
    if r.returncode != 0:
        return err or "Failed."
    return out or "Done."


def read_account(user):
    try:
        d = {}
        for line in open(f"{ACCOUNTS}/{user}", encoding="utf-8"):
            if "=" in line:
                k, v = line.strip().split("=", 1)
                d[k] = v
        return d
    except OSError:
        return {}


def read_conf_value(key, default=""):
    try:
        for line in open("/etc/n4vpn/n4.conf", encoding="utf-8"):
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return default


def list_users():
    try:
        users = []
        for line in open("/etc/passwd", encoding="utf-8"):
            f = line.split(":")
            if len(f) >= 3 and int(f[2]) >= 1000 and f[0] != "nobody":
                users.append(f[0])
        return sorted(users)
    except Exception:
        return []


def gen_username():
    # Owner's shop-bot pattern: N4 + 3 digits + 1 letter = 6 chars,
    # letter at a random position among the last 4 chars.
    existing = set(list_users())
    for _ in range(50):
        digits = [secrets.choice(string.digits) for _ in range(3)]
        letter = secrets.choice(string.ascii_lowercase)
        tail = digits + [letter]
        secrets.SystemRandom().shuffle(tail)
        name = "N4" + "".join(tail)
        if name not in existing and valid_username(name.lower()):
            return name.lower()
    return None


def gen_password():
    # SSH is an exposed port, so auto passwords are stronger than the
    # shop bot's 6-digit pattern: 10 chars, no confusing 0/O/1/l/I.
    alphabet = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(10))


def find_share_link(user):
    import glob
    host = read_conf_value("HOST_DOMAIN", "")
    port = read_conf_value("SHARE_PORT", "8880")
    try:
        for path in glob.glob("/etc/n4vpn/shares/*.json"):
            try:
                d = json.load(open(path, encoding="utf-8"))
            except Exception:
                continue
            if d.get("username") == user:
                token = path.rsplit("/", 1)[-1][:-5]
                return f"http://{host}:{port}/s/{token}"
    except Exception:
        pass
    return ""


def is_locked(user):
    try:
        for line in open("/etc/shadow", encoding="utf-8"):
            f = line.split(":")
            if f[0] == user:
                return f[1].startswith("!")
    except Exception:
        pass
    return False


def is_online(user):
    try:
        r = subprocess.run(["pgrep", "-u", user], capture_output=True, timeout=10)
        return r.returncode == 0
    except Exception:
        return False


def user_detail(user):
    if user not in list_users():
        return f"User '{user}' not found."
    d = read_account(user)
    today = datetime.date.today()
    expiry = d.get("EXPIRY", "")
    days_left = None
    if expiry:
        try:
            days_left = (datetime.date.fromisoformat(expiry) - today).days
        except ValueError:
            days_left = None
    gb = int(d.get("GB_LIMIT", "0") or 0)
    used = int(d.get("USED_BYTES", "0") or 0)
    used_gb = used / (1024 ** 3)
    if gb > 0:
        # Clamp: never show a negative remaining (lock test 2026-10-30
        # showed -0.07 GB at Used 1.07/1 GB; remaining is 0 once over).
        rem_gb = max(0.0, gb - used_gb)
        gb_line = f"💾 GB Limit: {gb} GB\n📥 Used: {used_gb:.2f} GB\n📤 Remaining: {rem_gb:.2f} GB"
    else:
        gb_line = f"💾 GB Limit: Unlimited\n📥 Used: {used_gb:.2f} GB\n📤 Remaining: Unlimited"
    if days_left is not None and days_left < 0:
        status = "❌ Expired"
    elif gb > 0 and used_gb >= gb:
        status = "🔒 GB limit reached"
    elif is_locked(user):
        status = "🔒 Locked"
    else:
        status = "✅ Active"
    if days_left is None:
        exp_line = f"📅 Expiry: {expiry or '-'}"
    elif days_left < 0:
        exp_line = f"📅 Expiry: {expiry} (expired {-days_left} days ago)"
    elif days_left == 0:
        exp_line = f"📅 Expiry: {expiry} (last day)"
    else:
        exp_line = f"📅 Expiry: {expiry} ({days_left} days left)"
    online = "🟢 Online" if is_online(user) else "⚪ Offline"
    link = find_share_link(user)
    card = (f"👤 {user}\n━━━━━━━━━━━━━━\n"
            f"📊 Status: {status}\n{online}\n{exp_line}\n{gb_line}")
    if link:
        card += f"\n🔗 Share Link: {link}"
    return card


def format_create_result(helper_out, username, password):
    vals = {}
    for line in helper_out.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            vals[k.strip()] = v.strip()
    if not vals.get("USER"):
        return helper_out or "Failed."
    card = ("✅ Account Created!\n━━━━━━━━━━━━━━\n"
            f"👤 Username: {vals.get('USER', username)}\n")
    if password:
        card += f"🔑 Password: {password}\n"
    card += (f"📅 Expiry: {vals.get('EXPIRY', '-')}\n"
             f"💾 GB Limit: {vals.get('GB', '-')} GB (0 = unlimited)\n"
             f"👥 Session Limit: {vals.get('LIMIT', '-')}\n"
             f"🖥 SSH: {vals.get('SSH', '-')}\n"
             f"🔀 Hybrid: {vals.get('HYBRID', '-')}\n"
             f"🌐 WS Ports: {vals.get('WS', '-')}")
    if vals.get("SHARE"):
        card += f"\n🔗 Web Share Link: {vals.get('SHARE')}"
    return card


def home_text():

    host = ""
    try:
        for line in open("/etc/n4vpn/n4.conf", encoding="utf-8"):
            if line.startswith("HOST_DOMAIN="):
                host = line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    try:
        users = 0
        for line in open("/etc/passwd", encoding="utf-8"):
            f = line.split(":")
            if len(f) >= 3 and int(f[2]) >= 1000 and f[0] != "nobody":
                users += 1
    except Exception:
        users = 0
    return (f"★ N4 VPN\n━━━━━━━━━━━━━━\n"
            f"🖥 Host: {host or '-'}\n"
            f"👥 Users: {users}\n"
            f"━━━━━━━━━━━━━━\n"
            f"Choose an action below:")


def btn(text, cb=None, url=None, style=None):
    b = {"text": text}
    if cb is not None:
        b["callback_data"] = cb
    if url is not None:
        b["url"] = url
    if style is not None:
        b["style"] = style
    return b


def home_keyboard():
    # Layout standard: short labels = 2 per row, long = full-width row.
    # Colors (Bot API 9.4 style): success=green, primary=blue, danger=red.
    #   green  = main actions + confirms (Create, Renew)
    #   blue   = info / navigation / URLs (List, Usage, Support, Channel)
    #   red    = destructive only (Delete)
    #   default (no style) = Home / Back
    return {"inline_keyboard": [
        [btn("➕ Create Account", cb="create", style="success"),
         btn("📋 User List", cb="list", style="primary")],
        [btn("🔄 Renew", cb="renew_prompt", style="success"),
         btn("👤 Check User", cb="users", style="primary")],
        [btn("🗑 Delete Account", cb="delete_prompt", style="danger")],
        [btn("💬 Support", url="https://t.me/n4nd404", style="primary"),
         btn("📣 Channel", url="https://t.me/n4vpn", style="primary")],
    ]}


def users_keyboard():
    # Unified layout rule: short labels = 2 per row, long = full-width.
    # Two usernames share a row only if both are short (<=16 chars);
    # a long name gets its own row so buttons never squeeze/truncate.
    rows = []
    us = list_users()
    i = 0
    while i < len(us):
        if i + 1 < len(us) and len(us[i]) <= 16 and len(us[i + 1]) <= 16:
            rows.append([btn(f"👤 {us[i]}", cb=f"user:{us[i]}", style="primary"),
                         btn(f"👤 {us[i + 1]}", cb=f"user:{us[i + 1]}", style="primary")])
            i += 2
        else:
            rows.append([btn(f"👤 {us[i]}", cb=f"user:{us[i]}", style="primary")])
            i += 1
    rows.append([btn("🏠 Home", cb="home")])
    return {"inline_keyboard": rows}


def detail_keyboard(user):
    # Destructive = always full-width, everywhere (Home Delete is
    # full-width too). So Detail is 1-per-row: Renew, Delete, Home.
    return {"inline_keyboard": [
        [btn("🔄 Renew", cb=f"renew:{user}", style="success")],
        [btn("🗑 Delete", cb=f"delete:{user}", style="danger")],
        [btn("🏠 Home", cb="home")],
    ]}


def create_choice_keyboard():
    return {"inline_keyboard": [
        [btn("🎲 Auto Username & Password", cb="create_auto", style="success"),
         btn("✏️ Custom Username & Password", cb="create_custom", style="primary")],
        [btn("🏠 Home", cb="home")],
    ]}


def cancel_keyboard():
    # Every step prompt gets this single row, so a stale prompt can
    # never leave the user stranded without a way out.
    return {"inline_keyboard": [[btn("❌ Cancel", cb="cancel")]]}


def handle(text):


    parts = (text or "").strip().split()
    if not parts:
        return "Empty command."
    cmd = parts[0]
    if cmd == "/start":
        return home_text() + ("\n\nCommands also work by typing:\n"
                "/list\n/create <user> <pass> <days> <gb> [limit]\n"
                "/renew <user> <days> <gb>\n/delete <user>\n/usage <user>\n/cancel")
    if cmd == "/list":
        try:
            users = []
            for line in open("/etc/passwd", encoding="utf-8"):
                f = line.split(":")
                if len(f) >= 3 and int(f[2]) >= 1000 and f[0] != "nobody":
                    users.append(f[0])
        except Exception:
            users = []
        return "Users:\n" + "\n".join(users) if users else "No users."
    if cmd in ("/usage", "/check", "/detail"):
        if len(parts) < 2 or not valid_username(parts[1]):
            return "Usage: /usage <user>"
        return user_detail(parts[1])
    if cmd == "/create":
        if len(parts) < 5 or not valid_num(parts[3]) or not valid_num(parts[4]):
            return "Usage: /create <user|auto> <pass|auto> <days> <gb> [limit]"
        if len(parts) >= 6 and not valid_num(parts[5]):
            return "Invalid session limit."
        user = parts[1] if parts[1] != "auto" else (gen_username() or "")
        pw = parts[2] if parts[2] != "auto" else gen_password()
        if not user or not valid_username(user) or not pw:
            return "Auto-generate failed, try again."
        args = ["create", user, pw, parts[3], parts[4]] + ([parts[5]] if len(parts) >= 6 else [])
        return format_create_result(run_helper(args), user, pw)
    if cmd == "/renew":
        if len(parts) < 4 or not valid_username(parts[1]) or not valid_num(parts[2]) or not valid_num(parts[3]):
            return "Usage: /renew <user> <days> <gb>"
        return run_helper(["renew", parts[1], parts[2], parts[3]])
    if cmd == "/delete":
        if len(parts) < 2 or not valid_username(parts[1]):
            return "Invalid username."
        return run_helper(["delete", parts[1]])
    return "Unknown command."


def tg(token, method, **params):
    data = json.dumps(params).encode()
    req = urllib.request.Request(f"https://api.telegram.org/bot{token}/{method}", data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=40) as resp:
        return json.load(resp)


def send_msg(token, chat, text, keyboard=None):
    params = {"chat_id": chat, "text": text[:4000]}
    if keyboard is not None:
        params["reply_markup"] = keyboard
    return tg(token, "sendMessage", **params)


def edit_msg(token, chat, message_id, text, keyboard=None):
    # Edit the tapped message in place instead of stacking a new one
    # (the Bot duplication bug: every callback used to sendMessage).
    # "message is not modified" is harmless (same text tapped twice).
    # Any other edit failure falls back to a new message, so the user
    # never loses the reply entirely.
    params = {"chat_id": chat, "message_id": message_id, "text": text[:4000]}
    if keyboard is not None:
        params["reply_markup"] = keyboard
    try:
        return tg(token, "editMessageText", **params)
    except Exception as e:
        if "message is not modified" in str(e):
            return None
        return send_msg(token, chat, text, keyboard=keyboard)


def clear_keyboard(token, chat, message_id):
    # Kill stale buttons on a message that is being superseded
    # (e.g. a step prompt after the final result is sent as new).
    try:
        tg(token, "editMessageReplyMarkup", chat_id=chat, message_id=message_id,
           reply_markup={"inline_keyboard": []})
    except Exception:
        pass


def cb_show(token, chat, message_id, text, keyboard=None):
    # Callback reply: edit in place when we have the tapped message,
    # otherwise send new (e.g. a callback without a message object).
    if message_id:
        return edit_msg(token, chat, message_id, text, keyboard=keyboard)
    return send_msg(token, chat, text, keyboard=keyboard)


def step_show(token, chat, state, text, keyboard=None):
    # Step-flow prompt: edit the flow's own message when tracked,
    # otherwise send new. Keyboard defaults to the Cancel row.
    if keyboard is None:
        keyboard = cancel_keyboard()
    mid = (state or {}).get("mid")
    if mid:
        return edit_msg(token, chat, mid, text, keyboard=keyboard)
    return send_msg(token, chat, text, keyboard=keyboard)


def poll(token):
    owner = load_owner_id()
    offset = 0
    # Create step-flow state, in-memory only (never written to disk,
    # so a password in progress never sits in a file; restart = restart flow).
    # chat_id -> {"step": "user"|"pass"|"days"|"gb", "user": "", "pass": "", "days": ""}
    states = {}
    while True:
        try:
            res = tg(token, "getUpdates", offset=offset, timeout=30)
            for upd in res.get("result", []):
                offset = upd["update_id"] + 1
                # --- Inline button taps ---
                cb = upd.get("callback_query") or {}
                if cb:
                    chat = (cb.get("message") or {}).get("chat", {}).get("id")
                    mid = (cb.get("message") or {}).get("message_id")
                    sender = (cb.get("from") or {}).get("id")
                    try:
                        tg(token, "answerCallbackQuery", callback_query_id=cb["id"])
                    except Exception:
                        pass
                    if not chat:
                        continue
                    if str(sender) != owner:
                        send_msg(token, chat, "Not authorized.")
                        continue
                    data = cb.get("data") or ""
                    if data == "home":
                        states.pop(chat, None)
                        cb_show(token, chat, mid, home_text(), keyboard=home_keyboard())
                    elif data == "cancel":
                        states.pop(chat, None)
                        cb_show(token, chat, mid, home_text(), keyboard=home_keyboard())
                    elif data == "list":
                        states.pop(chat, None)
                        cb_show(token, chat, mid, handle("/list"), keyboard=home_keyboard())
                    elif data == "create":
                        states.pop(chat, None)
                        cb_show(token, chat, mid, "➕ Create Account\n\nChoose how to create:", keyboard=create_choice_keyboard())
                    elif data == "create_auto":
                        u = gen_username(); pw = gen_password()
                        if not u or not pw:
                            cb_show(token, chat, mid, "Auto-generate failed, try again.", keyboard=home_keyboard())
                        else:
                            states[chat] = {"kind": "create", "step": "days", "user": u, "pass": pw, "mid": mid}
                            cb_show(token, chat, mid, f"🎲 Auto-generated (save this):\n👤 Username: {u}\n🔑 Password: {pw}\n\nSend days (number, e.g. 30):", keyboard=cancel_keyboard())
                    elif data == "create_custom":
                        states[chat] = {"kind": "create", "step": "user", "mid": mid}
                        cb_show(token, chat, mid, "➕ Create Account\n\nSend username:", keyboard=cancel_keyboard())
                    elif data == "users":
                        states.pop(chat, None)
                        us = list_users()
                        if not us:
                            cb_show(token, chat, mid, "No users.", keyboard=home_keyboard())
                        else:
                            cb_show(token, chat, mid, "👤 Choose a user to check:", keyboard=users_keyboard())
                    elif data.startswith("user:"):
                        states.pop(chat, None)
                        cb_show(token, chat, mid, user_detail(data[5:]), keyboard=detail_keyboard(data[5:]))
                    elif data.startswith("renew:"):
                        states[chat] = {"kind": "renew", "step": "days", "user": data[6:], "mid": mid}
                        cb_show(token, chat, mid, f"🔄 Renew {data[6:]}\n\nSend days (number):", keyboard=cancel_keyboard())
                    elif data.startswith("delete:"):
                        states.pop(chat, None)
                        u = data[7:]
                        # Destructive full-width; Cancel returns to the
                        # detail card (was: home, losing the user card).
                        cb_show(token, chat, mid, f"⚠️ Delete {u} permanently?", keyboard={"inline_keyboard": [[btn("✅ Yes, Delete", cb=f"delyes:{u}", style="danger")], [btn("❌ Cancel", cb=f"user:{u}")]]})
                    elif data.startswith("delyes:"):
                        u = data[7:]
                        states.pop(chat, None)
                        cb_show(token, chat, mid, run_helper(["delete", u]), keyboard=home_keyboard())
                    elif data == "renew_prompt":
                        cb_show(token, chat, mid, "Send: /renew <user> <days> <gb>", keyboard=home_keyboard())
                    elif data == "usage_prompt":
                        cb_show(token, chat, mid, "Send: /usage <user>", keyboard=home_keyboard())
                    elif data == "delete_prompt":
                        cb_show(token, chat, mid, "⚠️ Delete is permanent.\nSend: /delete <user>", keyboard=home_keyboard())
                    continue
                # --- Text messages ---
                msg = upd.get("message") or {}
                text = msg.get("text") or ""
                chat = (msg.get("chat") or {}).get("id")
                sender = (msg.get("from") or {}).get("id")
                if text and chat:
                    if str(sender) != owner:
                        send_msg(token, chat, "Not authorized.")
                        continue
                    if text.strip() == "/cancel":
                        old = states.pop(chat, None)
                        if old and old.get("mid"):
                            clear_keyboard(token, chat, old["mid"])
                        send_msg(token, chat, "Cancelled.", keyboard=home_keyboard())
                        continue
                    st = states.get(chat)
                    if st:
                        step = st["step"]; kind = st.get("kind", "create")
                        if kind == "renew":
                            if step == "days":
                                if not valid_num(text.strip()):
                                    step_show(token, chat, st, "Days must be a number. Send days again:")
                                    continue
                                st["days"] = text.strip(); st["step"] = "gb"
                                step_show(token, chat, st, "Send GB limit in GB (0 = unlimited):")
                                continue
                            if step == "gb":
                                if not valid_num(text.strip()):
                                    step_show(token, chat, st, "GB must be a number. Send GB again:")
                                    continue
                                out = run_helper(["renew", st["user"], st["days"], text.strip()])
                                done = states.pop(chat, None)
                                if done and done.get("mid"):
                                    clear_keyboard(token, chat, done["mid"])
                                send_msg(token, chat, out + "\n\n" + user_detail(st["user"]), keyboard=home_keyboard())
                                continue
                        if step == "user":
                            if not valid_username(text.strip()):
                                step_show(token, chat, st, "Invalid username. Send username again (2-32 chars: a-z, 0-9, _ or -):")
                                continue
                            st["user"] = text.strip(); st["step"] = "pass"
                            step_show(token, chat, st, "Send password:")
                            continue
                        if step == "pass":
                            st["pass"] = text.strip(); st["step"] = "days"
                            step_show(token, chat, st, "Send days (number, e.g. 30):")
                            continue
                        if step == "days":
                            if not valid_num(text.strip()):
                                step_show(token, chat, st, "Days must be a number. Send days again:")
                                continue
                            st["days"] = text.strip(); st["step"] = "gb"
                            step_show(token, chat, st, "Send GB limit in GB (0 = unlimited):")
                            continue
                        if step == "gb":
                            if not valid_num(text.strip()):
                                step_show(token, chat, st, "GB must be a number. Send GB again:")
                                continue
                            out = run_helper(["create", st["user"], st["pass"], st["days"], text.strip()])
                            result = format_create_result(out, st["user"], st["pass"])
                            done = states.pop(chat, None)
                            if done and done.get("mid"):
                                clear_keyboard(token, chat, done["mid"])
                            send_msg(token, chat, result, keyboard=home_keyboard())
                            continue
                    if text.strip() == "/start":
                        send_msg(token, chat, handle("/start"), keyboard=home_keyboard())
                    else:
                        send_msg(token, chat, handle(text), keyboard=home_keyboard())
        except Exception:
            time.sleep(5)


if __name__ == "__main__":
    token = load_token()
    if not token:
        print("No BOT_TOKEN in /etc/n4vpn/bot.conf. Run bot-setup.sh first.", file=sys.stderr)
        sys.exit(2)
    if len(sys.argv) > 1 and sys.argv[1] == "--poll":
        poll(token)
    else:
        print(handle(" ".join(sys.argv[1:]) or "/start"))
