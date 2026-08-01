#!/bin/bash
# ============================================================
#  install.sh — Master Installer OpenVPN & Multi-Tunnel Autoscript
#  Supports: Debian 10/11/12, Ubuntu 20.04/22.04
#  Tunnels : SSH, Dropbear, Stunnel4, SSH-WS, OpenVPN TCP & UDP,
#            Xray (Vmess, Vless, Trojan), BadVPN UDPGW (7100-7300)
# ============================================================

export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# ── Colors & Header ─────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BWHITE='\033[1;37m'
NC='\033[0m'

clear
echo -e "${CYAN}"
echo "=========================================================="
echo "    AUTOSCRIPT INSTALLER OPENVPN & MULTI-TUNNEL UDP       "
echo "=========================================================="
echo -e "${NC}"

# ── Root Check ─────────────────────────────────────────────
if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}[ERROR] Installer ini harus dijalankan sebagai root!${NC}"
    exit 1
fi

# ── Domain Setup ───────────────────────────────────────────
MYIP=$(curl -sS ifconfig.me || curl -sS ipinfo.io/ip)
echo -e "IP VPS Kamu: ${GREEN}${MYIP}${NC}"
echo ""
read -rp "Masukkan Domain / Subdomain untuk VPS: " DOMAIN

if [[ -z "${DOMAIN}" ]]; then
    echo -e "${YELLOW}Domain kosong, menggunakan IP (${MYIP}) sebagai domain.${NC}"
    DOMAIN="${MYIP}"
fi

# ── Detect Script Location ─────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Config Directory Setup ─────────────────────────────────
mkdir -p /etc/vpn
mkdir -p /etc/vpn/lib
mkdir -p /etc/vpn/scripts/ssh
mkdir -p /etc/vpn/scripts/xray
mkdir -p /etc/vpn/scripts/openvpn
mkdir -p /etc/vpn/scripts/system
mkdir -p /etc/vpn/scripts/menu
mkdir -p /etc/vpn/scripts/api
mkdir -p /var/log/vpn
mkdir -p /etc/xray
mkdir -p /etc/openvpn/server
mkdir -p /etc/openvpn/clients
mkdir -p /etc/openvpn/easy-rsa

# Copy local scripts & bot to /etc/vpn
if [[ -d "${SCRIPT_DIR}/scripts" ]]; then
    cp -r "${SCRIPT_DIR}/scripts/"* /etc/vpn/scripts/ 2>/dev/null
fi
if [[ -d "${SCRIPT_DIR}/bot" ]]; then
    mkdir -p /etc/vpn/bot
    cp -r "${SCRIPT_DIR}/bot/"* /etc/vpn/bot/ 2>/dev/null
fi

# Save Config
cat > /etc/vpn/config.conf <<EOF
IP=${MYIP}
DOMAIN=${DOMAIN}
PORT_SSH=22
PORT_DROPBEAR=143,109
PORT_STUNNEL=447,777
PORT_SSHWS=80
PORT_SSLWS=443
PORT_OVPN_TCP=1194
PORT_OVPN_UDP=1194
PORT_UDPGW=7100-7300
EOF

echo -e "${GREEN}[INFO] Memperbarui package repository & memasang dependensi Python Bot...${NC}"
apt update -y
apt install -y curl wget jq python3 python3-pip net-tools openvpn easy-rsa nginx dropbear stunnel4 fail2ban iptables-persistent screen cron iptables
pip3 install python-telegram-bot==13.15 requests qrcode pillow &>/dev/null || pip3 install python-telegram-bot requests qrcode pillow &>/dev/null

# ── Telegram Bot Setup ─────────────────────────────────────
echo ""
echo -e "${CYAN}── Pengaturan Telegram Bot ──────────────────────────────────${NC}"
read -rp "Masukkan Telegram Bot Token (Opsional / Tap Enter jika nanti): " BOT_TOKEN
read -rp "Masukkan Telegram Admin User ID (Opsional / Tap Enter jika nanti): " ADMIN_ID
echo ""
echo "Konfigurasi DANA Payment Gateway (opsional; hanya untuk merchant DANA resmi)."
echo "Kosongkan semua kolom jika belum memiliki kredensial DANA Gateway."
read -rp "DANA Merchant ID: " DANA_MERCHANT_ID
read -rp "DANA Client ID: " DANA_CLIENT_ID
read -rsp "DANA Client Secret: " DANA_CLIENT_SECRET
echo ""
read -rp "Environment DANA [sandbox/production] (default: sandbox): " DANA_ENV
DANA_ENV="${DANA_ENV:-sandbox}"

if [[ -f "/etc/vpn/bot/config.json" ]]; then
    python3 - /etc/vpn/bot/config.json "${BOT_TOKEN}" "${ADMIN_ID}" "${DANA_MERCHANT_ID}" "${DANA_CLIENT_ID}" "${DANA_CLIENT_SECRET}" "${DANA_ENV}" <<'PYEOF'
import json
import sys

config_path, bot_token, admin_id, merchant_id, client_id, client_secret, environment = sys.argv[1:]
with open(config_path, 'r') as handle:
    cfg = json.load(handle)
if bot_token:
    cfg['bot_token'] = bot_token
if admin_id:
    try:
        cfg['admin_ids'] = [int(admin_id)]
    except ValueError:
        pass
if merchant_id or client_id or client_secret:
    gateway = cfg.setdefault('dana_gateway', {})
    gateway['merchant_id'] = merchant_id
    gateway['client_id'] = client_id
    gateway['client_secret'] = client_secret
    gateway['environment'] = environment if environment in ('sandbox', 'production') else 'sandbox'
with open(config_path, 'w') as handle:
    json.dump(cfg, handle, indent=2)
PYEOF
fi

# Systemd Bot Service
cat > /etc/systemd/system/bot-vpn.service <<EOF
[Unit]
Description=VPN Telegram Bot Service
After=network.target

[Service]
Type=simple
WorkingDirectory=/etc/vpn/bot
ExecStart=/usr/bin/python3 /etc/vpn/bot/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
if [[ -n "${BOT_TOKEN}" ]]; then
    systemctl enable --now bot-vpn.service &>/dev/null
fi

# Enable all installed core services now and on every reboot. The bot remains
# opt-in until a token has been configured.
systemctl enable --now ssh cron nginx dropbear stunnel4 fail2ban &>/dev/null || true

# ── Install BadVPN UDPGW ───────────────────────────────────
echo -e "${GREEN}[INFO] Memasang BadVPN UDPGW (Ports 7100, 7200, 7300)...${NC}"
if [[ -f "${SCRIPT_DIR}/bin/badvpn-udpgw" ]]; then
    cp "${SCRIPT_DIR}/bin/badvpn-udpgw" /usr/bin/badvpn-udpgw
else
    # Fallback compilation/download if binary not present locally
    wget -qO /usr/bin/badvpn-udpgw "https://raw.githubusercontent.com/brutalX-04/open-vpn/main/bin/badvpn-udpgw" 2>/dev/null || true
fi
chmod +x /usr/bin/badvpn-udpgw 2>/dev/null

# Create BadVPN Service
cat > /etc/systemd/system/badvpn-7100.service <<EOF
[Unit]
Description=BadVPN UDPGW 7100
After=network.target

[Service]
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:7100 --max-clients 500
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/badvpn-7200.service <<EOF
[Unit]
Description=BadVPN UDPGW 7200
After=network.target

[Service]
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:7200 --max-clients 500
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/badvpn-7300.service <<EOF
[Unit]
Description=BadVPN UDPGW 7300
After=network.target

[Service]
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now badvpn-7100 badvpn-7200 badvpn-7300 &>/dev/null

# ── Setup OpenVPN Server (TCP & UDP) ───────────────────────
echo -e "${GREEN}[INFO] Mengonfigurasi OpenVPN TCP & UDP...${NC}"
cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/
cd /etc/openvpn/easy-rsa/ || exit 1
./easyrsa --batch init-pki &>/dev/null
./easyrsa --batch build-ca nopass &>/dev/null
./easyrsa --batch build-server-full server nopass &>/dev/null
./easyrsa --batch gen-crl &>/dev/null
openvpn --genkey secret /etc/openvpn/ta.key &>/dev/null

cp pki/ca.crt pki/issued/server.crt pki/private/server.key pki/crl.pem /etc/openvpn/server/
cp pki/crl.pem /etc/openvpn/crl.pem

# OpenVPN Server TCP Config
cat > /etc/openvpn/server/server-tcp.conf <<EOF
port 1194
proto tcp
dev tun
ca /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key /etc/openvpn/server/server.key
dh none
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /etc/openvpn/server/ipp-tcp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
keepalive 10 120
tls-auth /etc/openvpn/ta.key 0
crl-verify /etc/openvpn/crl.pem
cipher AES-256-CBC
auth SHA512
user nobody
group nogroup
persist-key
persist-tun
status /etc/openvpn/server/openvpn-tcp.log
verb 3
EOF

# OpenVPN Server UDP Config (⚡ Low Latency / Fast)
cat > /etc/openvpn/server/server-udp.conf <<EOF
port 1194
proto udp
dev tun
ca /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key /etc/openvpn/server/server.key
dh none
topology subnet
server 10.9.0.0 255.255.255.0
ifconfig-pool-persist /etc/openvpn/server/ipp-udp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
keepalive 10 120
tls-auth /etc/openvpn/ta.key 0
crl-verify /etc/openvpn/crl.pem
cipher AES-256-CBC
auth SHA512
user nobody
group nogroup
persist-key
persist-tun
explicit-exit-notify 1
status /etc/openvpn/server/openvpn-udp.log
verb 3
EOF

# Enable IP Forwarding
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn.conf
sysctl -p /etc/sysctl.d/99-openvpn.conf &>/dev/null

# IPTables Nat Rules for OpenVPN
NIC=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "${NIC}" -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o "${NIC}" -j MASQUERADE
netfilter-persistent save &>/dev/null

cat > /etc/systemd/system/vpn-openvpn-tcp.service <<'EOF'
[Unit]
Description=OpenVPN TCP server
After=network.target

[Service]
ExecStart=/usr/sbin/openvpn --config /etc/openvpn/server/server-tcp.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/vpn-openvpn-udp.service <<'EOF'
[Unit]
Description=OpenVPN UDP server
After=network.target

[Service]
ExecStart=/usr/sbin/openvpn --config /etc/openvpn/server/server-udp.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vpn-openvpn-tcp vpn-openvpn-udp &>/dev/null

# ── Setup Xray Base Config ─────────────────────────────────
echo -e "${GREEN}[INFO] Mengonfigurasi Xray Core...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install &>/dev/null

cat > /etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 10001,
      "protocol": "vmess",
      "tag": "vmess-ws",
      "settings": { "clients": [] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess" } }
    },
    {
      "port": 10002,
      "protocol": "vless",
      "tag": "vless-ws",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless" } }
    },
    {
      "port": 10003,
      "protocol": "trojan",
      "tag": "trojan-ws",
      "settings": { "clients": [] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan-ws" } }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

systemctl enable --now xray &>/dev/null

# ── Setup Cron Cleanup Job ─────────────────────────────────
cat > /etc/systemd/system/vpn-expiry-cleanup.service <<'EOF'
[Unit]
Description=Remove expired VPN accounts
After=network.target

[Service]
Type=oneshot
ExecStart=/etc/vpn/scripts/system/cleanup.sh
EOF

cat > /etc/systemd/system/vpn-expiry-cleanup.timer <<'EOF'
[Unit]
Description=Run VPN expiry cleanup every minute

[Timer]
OnCalendar=*-*-* *:*:00
Persistent=true
AccuracySec=1s
Unit=vpn-expiry-cleanup.service

[Install]
WantedBy=timers.target
EOF

rm -f /etc/cron.d/vpn-cleanup
systemctl daemon-reload
systemctl enable --now vpn-expiry-cleanup.timer
systemctl start vpn-expiry-cleanup.service

# ── Symlinks to /usr/bin for CLI Commands ─────────────────
ln -sf /etc/vpn/scripts/menu/main.sh /usr/bin/menu
ln -sf /etc/vpn/scripts/menu/menu-ssh.sh /usr/bin/menu-ssh
ln -sf /etc/vpn/scripts/menu/menu-xray.sh /usr/bin/menu-xray
ln -sf /etc/vpn/scripts/menu/menu-ovpn.sh /usr/bin/menu-ovpn
ln -sf /etc/vpn/scripts/system/status.sh /usr/bin/running
ln -sf /etc/vpn/scripts/system/status.sh /usr/bin/status
ln -sf /etc/vpn/scripts/system/restart.sh /usr/bin/restart-service
ln -sf /etc/vpn/scripts/api/cli.py /usr/bin/vpn-cli

chmod +x /etc/vpn/scripts/lib/*.sh 2>/dev/null
chmod +x /etc/vpn/scripts/*/*.sh 2>/dev/null
chmod +x /etc/vpn/scripts/api/cli.py 2>/dev/null
chmod +x /etc/vpn/bot/bot.py 2>/dev/null
chmod +x /usr/bin/menu* /usr/bin/running /usr/bin/status /usr/bin/vpn-cli 2>/dev/null

clear
echo -e "${GREEN}"
echo "=========================================================="
echo "      INSTALASI AUTOSCRIPT SELESAI DENGAN SUKSES!         "
echo "=========================================================="
echo -e "${NC}"
echo -e "Ketik '${BWHITE}menu${NC}' untuk membuka Menu Utama."
echo -e "Gunakan '${BWHITE}vpn-cli${NC}' untuk integrasi Telegram Bot / API."
echo -e "Bot Telegram Service: '${BWHITE}systemctl status bot-vpn${NC}'"
echo ""
EOF
