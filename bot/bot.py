#!/usr/bin/env python3
# ============================================================
#  bot/bot.py — Telegram Bot VPN Store
#  Automatic Payment: Xendit Payments API v3 (QRIS)
#  Design: Clean, Professional, No Emojis
# ============================================================

import os
import sys
import io
import json
import html
import logging
import random
import datetime
import fcntl
from typing import Dict, Any

import qrcode
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, ParseMode
from telegram.ext import (
    Updater, CommandHandler, CallbackQueryHandler, MessageHandler,
    Filters, CallbackContext
)

# Logging
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

# Paths
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, "config.json")
TRIAL_LOG_FILE = os.path.join(BASE_DIR, "trial_users.json")

# The bot is executed directly by systemd (`python3 bot.py`), so its parent
# directory must take precedence when importing the sibling CLI package.
sys.path.insert(0, os.path.dirname(BASE_DIR))
from scripts.api import cli
from xendit_gateway import XenditPaymentGateway

def load_config() -> Dict[str, Any]:
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, 'r') as f:
            return json.load(f)
    return {
        "bot_token": "",
        "admin_ids": [],
        "xendit": {"secret_key": ""},
        "prices": {
            "ssh": {"7": 5000, "14": 9000, "30": 15000},
            "vmess": {"7": 6000, "14": 10000, "30": 18000},
            "vless": {"7": 6000, "14": 10000, "30": 18000},
            "trojan": {"7": 6000, "14": 10000, "30": 18000},
            "ovpn": {"7": 7000, "14": 12000, "30": 20000}
        }
    }

def save_config(config: Dict[str, Any]):
    with open(CONFIG_FILE, 'w') as f:
        json.dump(config, f, indent=2)

def is_admin(user_id: int) -> bool:
    config = load_config()
    return user_id in config.get("admin_ids", [])

def format_rupiah(val: int) -> str:
    return f"Rp {val:,.0f}".replace(",", ".")

def format_aligned_rows(rows) -> str:
    """Return Telegram-safe, monospaced key/value rows with aligned labels."""
    width = max(len(label) for label, _ in rows)
    return "\n".join(
        f"{label:<{width}} : {html.escape(str(value))}"
        for label, value in rows
    )

def send_config_file(message, content: str, filename: str, caption: str) -> None:
    """Send long connection data as a downloadable file instead of wrapped chat text."""
    document = io.BytesIO(content.encode("utf-8"))
    document.name = filename
    message.reply_document(document=document, filename=filename, caption=caption)

def get_xendit_gateway() -> XenditPaymentGateway:
    config = load_config()
    xendit = config.get("xendit", {})
    return XenditPaymentGateway(secret_key=xendit.get("secret_key", ""))

def generate_qr_image_bytes(qr_data: str) -> io.BytesIO:
    """Generates QR code PNG image in memory buffer"""
    qr = qrcode.QRCode(
        version=1,
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        box_size=10,
        border=2,
    )
    qr.add_data(qr_data)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    
    buf = io.BytesIO()
    img.save(buf, format='PNG')
    buf.seek(0)
    return buf

def reserve_trial(user_id: int) -> bool:
    """Atomically reserve one trial for a Telegram user on the server date."""
    lock_path = f"{TRIAL_LOG_FILE}.lock"
    today = datetime.date.today().isoformat()
    with open(lock_path, "a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            with open(TRIAL_LOG_FILE, "r") as handle:
                trials = json.load(handle)
        except (FileNotFoundError, json.JSONDecodeError):
            trials = {}
        last_trial = trials.get(str(user_id))
        if isinstance(last_trial, (int, float)):
            last_trial = datetime.datetime.fromtimestamp(last_trial).date().isoformat()
        if last_trial == today:
            return False
        trials[str(user_id)] = today
        temp_file = f"{TRIAL_LOG_FILE}.tmp"
        with open(temp_file, "w") as handle:
            json.dump(trials, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_file, TRIAL_LOG_FILE)
        return True

def release_trial_reservation(user_id: int) -> None:
    """Allow a retry only when creating the reserved trial failed."""
    lock_path = f"{TRIAL_LOG_FILE}.lock"
    today = datetime.date.today().isoformat()
    with open(lock_path, "a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            with open(TRIAL_LOG_FILE, "r") as handle:
                trials = json.load(handle)
        except (FileNotFoundError, json.JSONDecodeError):
            return
        if trials.get(str(user_id)) == today:
            trials.pop(str(user_id), None)
            temp_file = f"{TRIAL_LOG_FILE}.tmp"
            with open(temp_file, "w") as handle:
                json.dump(trials, handle)
            os.replace(temp_file, TRIAL_LOG_FILE)

# ── Command Handlers ────────────────────────────────────────

def start(update: Update, context: CallbackContext):
    user = update.effective_user
    config = load_config()
    status_res = cli.get_status()
    s_data = status_res.get("data", {})

    ip = s_data.get("ip", "N/A")
    domain = s_data.get("domain", "N/A")
    uptime = s_data.get("uptime", "N/A")
    ram = s_data.get("ram", {})
    ram_used = ram.get("used_mb", 0)
    ram_total = ram.get("total_mb", 0)
    user_counts = s_data.get("user_counts", {})
    identity = format_aligned_rows([
        ("User ID", user.id),
        ("Nama", user.first_name),
    ])
    server_info = format_aligned_rows([
        ("Host / IP", ip),
        ("Domain", domain),
        ("Uptime", uptime),
        ("RAM", f"{ram_used} MB / {ram_total} MB"),
        ("Akun SSH", user_counts.get("ssh", 0)),
        ("Klien Xray", user_counts.get("xray", 0)),
    ])

    msg = f"""<b>SYSTEM STORE VPN PREMIUM</b>

<pre>{identity}</pre>

<b>INFORMASI SERVER VPS</b>
<pre>{server_info}</pre>

Silakan pilih layanan di bawah ini:"""

    keyboard = [
        [
            InlineKeyboardButton("Buy SSH", callback_data="buy_ssh"),
            InlineKeyboardButton("Buy Vmess", callback_data="buy_vmess")
        ],
        [
            InlineKeyboardButton("Buy Vless", callback_data="buy_vless"),
            InlineKeyboardButton("Buy Trojan", callback_data="buy_trojan")
        ],
        [
            InlineKeyboardButton("Buy OpenVPN (TCP/UDP)", callback_data="buy_ovpn")
        ],
        [
            InlineKeyboardButton("Create Trial (3 Jam)", callback_data="create_trial")
        ]
    ]

    if is_admin(user.id):
        keyboard.append([InlineKeyboardButton("Admin Panel", callback_data="admin_panel")])

    reply_markup = InlineKeyboardMarkup(keyboard)

    if update.message:
        update.message.reply_text(msg, parse_mode=ParseMode.HTML, reply_markup=reply_markup)
    elif update.callback_query:
        try:
            update.callback_query.edit_message_text(msg, parse_mode=ParseMode.HTML, reply_markup=reply_markup)
        except:
            update.callback_query.message.reply_text(msg, parse_mode=ParseMode.HTML, reply_markup=reply_markup)

# ── Buy Flow & QR Code Payment ─────────────────────────────

def buy_menu(update: Update, context: CallbackContext):
    query = update.callback_query
    query.answer()
    proto = query.data.replace("buy_", "")

    config = load_config()
    prices = config.get("prices", {}).get(proto, {})

    proto_names = {
        "ssh": "SSH & OpenSSH",
        "vmess": "Xray Vmess WS/gRPC",
        "vless": "Xray Vless WS/gRPC",
        "trojan": "Xray Trojan WS/gRPC",
        "ovpn": "OpenVPN (TCP & UDP)"
    }

    p_name = proto_names.get(proto, proto.upper())

    msg = f"""<b>PEMBELIAN AKUN {p_name.upper()}</b>

Pilih durasi masa aktif yang diinginkan:

- 7 Hari (1 Minggu)  : {format_rupiah(prices.get('7', 5000))}
- 14 Hari (2 Minggu) : {format_rupiah(prices.get('14', 9000))}
- 30 Hari (1 Bulan)  : {format_rupiah(prices.get('30', 15000))}"""

    keyboard = [
        [
            InlineKeyboardButton(f"7 Hari - {format_rupiah(prices.get('7', 5000))}", callback_data=f"select_{proto}_7"),
        ],
        [
            InlineKeyboardButton(f"14 Hari - {format_rupiah(prices.get('14', 9000))}", callback_data=f"select_{proto}_14"),
        ],
        [
            InlineKeyboardButton(f"30 Hari - {format_rupiah(prices.get('30', 15000))}", callback_data=f"select_{proto}_30"),
        ],
        [
            InlineKeyboardButton("Kembali", callback_data="start_menu")
        ]
    ]

    query.edit_message_text(msg, parse_mode=ParseMode.HTML, reply_markup=InlineKeyboardMarkup(keyboard))

def select_duration(update: Update, context: CallbackContext):
    query = update.callback_query
    query.answer()
    parts = query.data.split("_")
    proto = parts[1]
    days = int(parts[2])

    config = load_config()
    amount = config.get("prices", {}).get(proto, {}).get(str(days), 10000)
    inv_id = f"INV{datetime.datetime.now().strftime('%Y%m%d%H%M%S')}"

    # Create a dynamic QRIS payment request through Xendit Payments API v3.
    xendit = get_xendit_gateway()
    success, order_res = xendit.create_order(reference_id=inv_id, amount=amount, title=f"Purchase {proto.upper()} {days}D")

    if not success:
        query.edit_message_text(f"Gagal memproses QR Code Payment Gateway: {order_res.get('error')}", parse_mode=ParseMode.HTML)
        return

    qr_str = order_res.get("qr_code", order_res.get("payment_url", inv_id))
    order_id = order_res.get("order_id", inv_id)

    # Generate QR Code image in memory
    qr_img_bytes = generate_qr_image_bytes(qr_str)

    tx_data = {
        "inv_id": inv_id,
        "order_id": order_id,
        "user_id": query.from_user.id,
        "proto": proto,
        "days": days,
        "amount": amount,
        "created_at": str(datetime.datetime.now())
    }

    context.user_data["pending_tx"] = tx_data

    caption_msg = f"""<b>PEMBAYARAN QRIS OTOMATIS</b>

Invoice ID: <code>{inv_id}</code>
Layanan: {proto.upper()} ({days} Hari)
Total: <b>{format_rupiah(amount)}</b>
Status: PENDING PAYMENT

<b>PETUNJUK PEMBAYARAN</b>
1. Scan QRIS di atas menggunakan aplikasi pembayaran yang mendukung QRIS.
2. Selesaikan pembayaran sesuai nominal yang tertera.
3. Klik tombol 'Cek Pembayaran' setelah berhasil."""

    keyboard = [
        [
            InlineKeyboardButton("Cek Pembayaran", callback_data=f"check_pay_{inv_id}")
        ],
        [
            InlineKeyboardButton("Batal", callback_data="start_menu")
        ]
    ]

    # Delete previous inline message and send Photo with QR Code
    try:
        query.message.delete()
    except:
        pass

    context.bot.send_photo(
        chat_id=update.effective_chat.id,
        photo=qr_img_bytes,
        caption=caption_msg,
        parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup(keyboard)
    )

def check_payment(update: Update, context: CallbackContext):
    query = update.callback_query
    query.answer()

    tx_data = context.user_data.get("pending_tx")
    if not tx_data:
        query.message.reply_text("Transaksi tidak ditemukan atau telah kadaluarsa.", parse_mode=ParseMode.HTML)
        return

    inv_id = tx_data["inv_id"]
    order_id = tx_data.get("order_id", inv_id)
    proto = tx_data["proto"]
    days = tx_data["days"]

    # Verify the current status with Xendit before provisioning an account.
    xendit = get_xendit_gateway()
    is_paid, status_str = xendit.check_order_status(payment_request_id=order_id)

    if not is_paid:
        query.answer(f"Status Pembayaran QR Code: {status_str}. Silakan tuntaskan Scan QR Code terlebih dahulu.", show_alert=True)
        return

    username = f"usr{random.randint(1000,9999)}"
    query.message.reply_text("Verifikasi pembayaran QR Code berhasil. Memproses pembuatan akun...", parse_mode=ParseMode.HTML)

    if proto == 'ssh':
        res = cli.create_user(proto='ssh', username=username, days=days, password=f"pass{random.randint(100,999)}")
    elif proto in ['vmess', 'vless', 'trojan']:
        res = cli.create_user(proto=proto, username=username, days=days)
    elif proto == 'ovpn':
        res_tcp = cli.create_user(proto='ovpn-tcp', username=username, days=days)
        res_udp = cli.create_user(proto='ovpn-udp', username=username, days=days)
        res = {"status": "success", "data": {"username": username, "tcp": res_tcp.get("data"), "udp": res_udp.get("data")}}
    else:
        res = cli.create_user(proto=proto, username=username, days=days)

    if res.get("status") == "success":
        data = res.get("data", {})
        config = cli.get_config()
        domain = config.get("DOMAIN", "N/A")

        out_msg = f"""<b>AKUN VPN BERHASIL DIBUAT</b>

Username: <code>{data.get('username', username)}</code>
Masa aktif: <code>{days} Hari</code>
Expired: <code>{data.get('expired', 'N/A')}</code>
Domain: <code>{domain}</code>
\n"""

        if proto == 'ssh':
            out_msg += f"""DETAIL SSH & WEBSOCKET:
Password      : <code>{data.get('password')}</code>
Port SSH      : <code>22</code>
Port Dropbear : <code>143, 109</code>
Port SSH-WS   : <code>80</code>
Port SSL-WS   : <code>443</code>
SSH-UDP       : <code>1-65535</code>
UDPGW         : <code>7100-7300</code>

Payload WSS:
<code>GET wss://{domain}/ [protocol][crlf]Host: bug[crlf]Upgrade: websocket[crlf][crlf]</code>"""

        elif proto in ['vmess', 'vless', 'trojan']:
            links = data.get("links", {})
            out_msg += f"""CONFIG {proto.upper()}:
UUID/Password : <code>{data.get('uuid')}</code>

WS TLS (443):
<code>{links.get('ws_tls')}</code>

WS non-TLS (80):
<code>{links.get('ws_none_tls')}</code>

gRPC TLS (443):
<code>{links.get('grpc')}</code>"""

        elif proto == 'ovpn':
            out_msg += f"""CONFIG OPENVPN:
OpenVPN TCP Port: 1194
OpenVPN UDP Port: 1194 (Fast Latency)
File .ovpn telah dibuat di server."""

        query.message.reply_text(out_msg, parse_mode=ParseMode.HTML)
        context.user_data.pop("pending_tx", None)
    else:
        query.message.reply_text(f"Gagal membuat akun: {res.get('message')}", parse_mode=ParseMode.HTML)

# ── Trial Handler ───────────────────────────────────────────

def create_trial(update: Update, context: CallbackContext):
    query = update.callback_query
    query.answer()
    user_id = query.from_user.id

    if not reserve_trial(user_id):
        try:
            query.edit_message_text(
                "Anda telah membuat trial hari ini. Coba lagi setelah pergantian tanggal server.",
                parse_mode=ParseMode.HTML
            )
        except:
            query.message.reply_text(
                "Anda telah membuat trial hari ini. Coba lagi setelah pergantian tanggal server.",
                parse_mode=ParseMode.HTML
            )
        return

    try:
        query.edit_message_text("Membuat paket Trial 3 Jam (SSH, Vmess, Vless, Trojan, OpenVPN)...", parse_mode=ParseMode.HTML)
    except:
        query.message.reply_text("Membuat paket Trial 3 Jam (SSH, Vmess, Vless, Trojan, OpenVPN)...", parse_mode=ParseMode.HTML)

    t_user = f"tr{random.randint(1000,9999)}"
    res = cli.create_trial_bundle(t_user, hours=3)

    if res.get("status") == "success":
        accs = res.get("accounts", {})
        ssh_acc = accs.get("ssh", {})
        vmess_acc = accs.get("vmess", {})
        vless_acc = accs.get("vless", {})
        trojan_acc = accs.get("trojan", {})
        ovpn_udp_acc = accs.get("ovpn-udp", {})

        config = cli.get_config()
        domain = config.get("DOMAIN", "N/A")
        ip = ssh_acc.get("ip", config.get("IP", domain))
        ssh_ports = ssh_acc.get("ports", {})
        ssh_port = ssh_ports.get("ssh", "22")
        dropbear_port = ssh_ports.get("dropbear", "143,109")
        http_port = ssh_ports.get("ws", "80")
        https_port = ssh_ports.get("ssl_ws", "443")
        ovpn_port = ovpn_udp_acc.get("port", "1194")
        ovpn_profile = os.path.basename(ovpn_udp_acc.get("file_path", "profil UDP tidak tersedia"))

        msg = f"""<b>PAKET TRIAL ALL-IN-ONE — 3 JAM</b>

Username: <code>{t_user}</code>
Masa aktif: <code>3 Jam</code>
Server: <code>{domain}</code>

<b>1. SSH &amp; OPENSSH</b>
Host/IP: <code>{ip}</code>
Username: <code>{ssh_acc.get('username', t_user)}</code>
Password: <code>{ssh_acc.get('password')}</code>
OpenSSH: <code>{ssh_port}</code>
Dropbear: <code>{dropbear_port}</code>

<b>HTTP CUSTOM / SSH WEBSOCKET</b>
Port HTTP: <code>{http_port}</code>
Port HTTPS: <code>{https_port}</code>
Host / SNI: <code>{domain}</code>
Payload:
<code>GET / HTTP/1.1[crlf]\nHost: {domain}[crlf]\nUpgrade: websocket[crlf][crlf]</code>
Catatan: HTTP Custom/WS memerlukan proxy WebSocket yang aktif di server.

<b>2. VMESS WS TLS</b>
Konfigurasi: <code>vmess-ws-tls.txt</code>

<b>3. VLESS WS TLS</b>
Konfigurasi: <code>vless-ws-tls.txt</code>

<b>4. TROJAN WSS TLS</b>
Konfigurasi: <code>trojan-wss-tls.txt</code>

<b>5. OPENVPN UDP FAST</b>
Remote: <code>{domain}:{ovpn_port}</code>
Protocol: <code>UDP</code>
Profile: <code>{ovpn_profile}</code>
Status: file profil dikirim sebagai dokumen."""

        query.message.reply_text(msg, parse_mode=ParseMode.HTML)
        send_config_file(query.message, vmess_acc.get("links", {}).get("ws_tls", ""), "vmess-ws-tls.txt", "VMess WS TLS")
        send_config_file(query.message, vless_acc.get("links", {}).get("ws_tls", ""), "vless-ws-tls.txt", "VLESS WS TLS")
        send_config_file(query.message, trojan_acc.get("links", {}).get("ws_tls", ""), "trojan-wss-tls.txt", "Trojan WSS TLS")
        send_config_file(
            query.message,
            ovpn_udp_acc.get("content", ""),
            ovpn_profile,
            "OpenVPN UDP profile",
        )
    else:
        release_trial_reservation(user_id)
        query.message.reply_text("Gagal membuat paket trial.", parse_mode=ParseMode.HTML)

# ── Admin Panel ─────────────────────────────────────────────

def admin_panel(update: Update, context: CallbackContext):
    query = update.callback_query
    query.answer()
    if not is_admin(query.from_user.id):
        query.message.reply_text("Akses ditolak. Pengguna bukan admin.", parse_mode=ParseMode.HTML)
        return

    msg = """<b>PANEL ADMINISTRATOR</b>

Pilih menu konfigurasi admin:"""

    keyboard = [
        [InlineKeyboardButton("Ubah Harga Produk", callback_data="admin_price_menu")],
        [InlineKeyboardButton("Konfigurasi Xendit", callback_data="admin_xendit_cfg")],
        [InlineKeyboardButton("Kembali ke Menu Utama", callback_data="start_menu")]
    ]

    try:
        query.edit_message_text(msg, parse_mode=ParseMode.HTML, reply_markup=InlineKeyboardMarkup(keyboard))
    except:
        query.message.reply_text(msg, parse_mode=ParseMode.HTML, reply_markup=InlineKeyboardMarkup(keyboard))

def admin_price_menu(update: Update, context: CallbackContext):
    query = update.callback_query
    query.answer()
    if not is_admin(query.from_user.id):
        return

    config = load_config()
    prices = config.get("prices", {})

    msg = f"""<b>KONFIGURASI HARGA PRODUK</b>

SSH    : 7d={prices.get('ssh',{}).get('7')}, 14d={prices.get('ssh',{}).get('14')}, 30d={prices.get('ssh',{}).get('30')}
Vmess  : 7d={prices.get('vmess',{}).get('7')}, 14d={prices.get('vmess',{}).get('14')}, 30d={prices.get('vmess',{}).get('30')}
Vless  : 7d={prices.get('vless',{}).get('7')}, 14d={prices.get('vless',{}).get('14')}, 30d={prices.get('vless',{}).get('30')}
Trojan : 7d={prices.get('trojan',{}).get('7')}, 14d={prices.get('trojan',{}).get('14')}, 30d={prices.get('trojan',{}).get('30')}
OVPN   : 7d={prices.get('ovpn',{}).get('7')}, 14d={prices.get('ovpn',{}).get('14')}, 30d={prices.get('ovpn',{}).get('30')}

Untuk mengubah harga produk, edit file /etc/vpn/bot/config.json"""

    keyboard = [[InlineKeyboardButton("Kembali", callback_data="admin_panel")]]
    try:
        query.edit_message_text(msg, parse_mode=ParseMode.HTML, reply_markup=InlineKeyboardMarkup(keyboard))
    except:
        query.message.reply_text(msg, parse_mode=ParseMode.HTML, reply_markup=InlineKeyboardMarkup(keyboard))

# ── Router & Callback Dispatcher ────────────────────────────

def callback_router(update: Update, context: CallbackContext):
    data = update.callback_query.data
    if data == "start_menu":
        start(update, context)
    elif data.startswith("buy_"):
        buy_menu(update, context)
    elif data.startswith("select_"):
        select_duration(update, context)
    elif data.startswith("check_pay_"):
        check_payment(update, context)
    elif data == "create_trial":
        create_trial(update, context)
    elif data == "admin_panel":
        admin_panel(update, context)
    elif data == "admin_price_menu":
        admin_price_menu(update, context)

def main():
    config = load_config()
    token = config.get("bot_token")
    if not token or token == "BOT_TOKEN_HERE":
        print("Warning: bot_token belum diisi di bot/config.json!")

    updater = Updater(token, use_context=True)
    dp = updater.dispatcher

    dp.add_handler(CommandHandler("start", start))
    dp.add_handler(CommandHandler("menu", start))
    dp.add_handler(CallbackQueryHandler(callback_router))

    logger.info("Bot VPN shop starting (QR Code Payment Gateway Enabled)...")
    updater.start_polling()
    updater.idle()

if __name__ == "__main__":
    main()
