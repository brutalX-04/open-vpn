#!/bin/bash
# ============================================================
#  install.sh — Master Installer OpenVPN & Multi-Tunnel Autoscript
#  Supports: Debian 10/11/12, Ubuntu 20.04/22.04/24.04
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

# Fail before touching the host when the distribution is outside the tested
# compatibility set. Keep this in sync with README.md and docs/DECISIONS.md.
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
else
    echo -e "${RED}[ERROR] Tidak dapat membaca /etc/os-release.${NC}"
    exit 1
fi
case "${ID}:${VERSION_ID}" in
    debian:10|debian:11|debian:12|ubuntu:20.04|ubuntu:22.04|ubuntu:24.04) ;;
    *)
        echo -e "${RED}[ERROR] OS tidak didukung: ${PRETTY_NAME:-${ID} ${VERSION_ID}}.${NC}"
        echo -e "${YELLOW}Didukung: Debian 10/11/12 dan Ubuntu 20.04/22.04/24.04.${NC}"
        exit 1
        ;;
esac

# ── Domain Setup ───────────────────────────────────────────
MYIP=$(curl -sS ifconfig.me || curl -sS ipinfo.io/ip)
echo -e "IP VPS Kamu: ${GREEN}${MYIP}${NC}"
echo ""
read -rp "Masukkan Domain / Subdomain untuk VPS: " DOMAIN

if [[ -z "${DOMAIN}" ]]; then
    echo -e "${YELLOW}Domain kosong, menggunakan IP (${MYIP}) sebagai domain.${NC}"
    DOMAIN="${MYIP}"
fi

PUBLIC_API_ENABLED=0
PUBLIC_API_HOST=""
API_ADMIN_EMAIL=""
XRAY_PROXY_ENABLED=0
XRAY_PROXY_HOST=""
XRAY_PROXY_SKIP_API=0
if [[ "${DOMAIN}" != "${MYIP}" && "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    read -rp "Siapkan profil klien Xray TLS/WebSocket untuk ${DOMAIN} sekarang? (A record dan TCP 80/443 harus siap) [y/N]: " ENABLE_XRAY_PROXY
    if [[ "${ENABLE_XRAY_PROXY}" =~ ^[Yy]$ ]]; then
        XRAY_PROXY_ENABLED=1
        XRAY_PROXY_HOST="${DOMAIN}"
    fi
    PUBLIC_API_HOST="api.${DOMAIN}"
    if [[ "${XRAY_PROXY_ENABLED}" == "1" ]]; then
        read -rp "Expose API juga pada subdomain terpisah ${PUBLIC_API_HOST}? (perlu DNS dan email Let's Encrypt) [y/N]: " ENABLE_PUBLIC_API
        if [[ "${ENABLE_PUBLIC_API}" =~ ^[Yy]$ ]]; then
            read -rp "Email admin untuk sertifikat Let's Encrypt: " API_ADMIN_EMAIL
            PUBLIC_API_ENABLED=1
        fi
    else
        read -rp "Expose API via HTTPS di ${PUBLIC_API_HOST} (DNS harus sudah menunjuk ke VPS)? [y/N]: " ENABLE_PUBLIC_API
        if [[ "${ENABLE_PUBLIC_API}" =~ ^[Yy]$ ]]; then
            read -rp "Email admin untuk sertifikat Let's Encrypt: " API_ADMIN_EMAIL
            PUBLIC_API_ENABLED=1
        fi
    fi
else
    echo -e "${YELLOW}[PERINGATAN] Domain TLS tidak tersedia. API tetap loopback-only; API key tidak akan dikirim lewat jaringan tanpa TLS.${NC}"
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
mkdir -p /etc/vpn/api /etc/vpn/vpnctl /etc/vpn/vpnctl/drivers
mkdir -p /var/lib/vpn
chmod 750 /var/lib/vpn
mkdir -p /var/log/vpn
mkdir -p /etc/xray
mkdir -p /etc/openvpn/server
mkdir -p /etc/openvpn/clients
mkdir -p /etc/openvpn/easy-rsa

# Copy local scripts to /etc/vpn. Do not continue with a partial
# installation: the menu and vpn-cli commands depend on these files.
if [[ ! -f "${SCRIPT_DIR}/scripts/menu/main.sh" || ! -f "${SCRIPT_DIR}/scripts/api/cli.py" ]]; then
    echo -e "${RED}[ERROR] File menu atau vpn-cli tidak ditemukan di ${SCRIPT_DIR}/scripts.${NC}"
    echo -e "${YELLOW}Jalankan installer dari folder repository yang lengkap.${NC}"
    exit 1
fi

cp -a "${SCRIPT_DIR}/scripts/." /etc/vpn/scripts/
# Shared UI library is loaded by every menu from /etc/vpn/lib.
cp -a "${SCRIPT_DIR}/scripts/lib/." /etc/vpn/lib/
cp -a "${SCRIPT_DIR}/api/." /etc/vpn/api/
cp -a "${SCRIPT_DIR}/vpnctl/." /etc/vpn/vpnctl/
rm -f /etc/vpn/scripts/system/vpn-tendang /etc/vpn/scripts/system/openvpn-single-session.sh

# Clean up legacy installation before configuring current services.
if [[ -d /etc/vpn/bot || -e /etc/systemd/system/bot-vpn.service ]]; then
    "${SCRIPT_DIR}/scripts/system/remove-bot.sh"
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

echo -e "${GREEN}[INFO] Memperbarui package repository & memasang dependensi sistem...${NC}"
apt update -y
apt install -y curl wget jq python3 python3-venv python3-pip net-tools openvpn easy-rsa nginx dropbear stunnel4 fail2ban iptables-persistent screen cron iptables openssl

# Enable password authentication for VPN SSH accounts. The filename is
# intentionally ordered before cloud-init's 60-cloudimg-settings.conf on
# images such as Oracle Linux/Ubuntu, where sshd uses the first value found.
SSHD_CONFIG_DIR=/etc/ssh/sshd_config.d
SSHD_VPN_CONFIG="${SSHD_CONFIG_DIR}/10-vpn-panel.conf"
mkdir -p "${SSHD_CONFIG_DIR}"
cat > "${SSHD_VPN_CONFIG}" <<'EOF'
PasswordAuthentication yes
EOF
chmod 0644 "${SSHD_VPN_CONFIG}"

# Validate before reloading so a malformed drop-in cannot disrupt SSH access.
if sshd -t; then
    if systemctl is-active --quiet ssh.service; then
        systemctl reload ssh.service
    elif systemctl is-active --quiet sshd.service; then
        systemctl reload sshd.service
    fi
else
    echo -e "${RED}[ERROR] Konfigurasi SSH tidak valid; periksa ${SSHD_VPN_CONFIG}.${NC}"
    exit 1
fi

python3 -m venv /etc/vpn/venv
/etc/vpn/venv/bin/pip install --upgrade pip
/etc/vpn/venv/bin/pip install -r /etc/vpn/api/requirements.txt

if [[ ! -f /etc/vpn/api.env ]]; then
    API_KEY_CREATED=1
    API_KEY=$(openssl rand -base64 48 | tr -d '=+/\n' | cut -c1-64)
    umask 077
    cat > /etc/vpn/api.env <<EOF
API_KEY=${API_KEY}
DOMAIN=${DOMAIN}
EOF
    chmod 600 /etc/vpn/api.env
else
    API_KEY_CREATED=0
fi

# Enable all installed core services now and on every reboot.
systemctl enable --now ssh cron nginx dropbear stunnel4 fail2ban &>/dev/null || true

if [[ "${PUBLIC_API_ENABLED}" == "1" ]]; then
    if bash "${SCRIPT_DIR}/scripts/system/configure-api-nginx.sh" "${PUBLIC_API_HOST}" "${API_ADMIN_EMAIL}"; then
        PUBLIC_API_ENABLED=1
    else
        PUBLIC_API_ENABLED=0
        echo -e "${YELLOW}API tetap lokal karena HTTPS reverse proxy belum berhasil dikonfigurasi.${NC}"
    fi
fi

# ── Install BadVPN UDPGW ───────────────────────────────────
echo -e "${GREEN}[INFO] Memasang BadVPN UDPGW (Ports 7100, 7200, 7300)...${NC}"
if [[ -f "${SCRIPT_DIR}/bin/badvpn-udpgw" ]]; then
    install -m 755 "${SCRIPT_DIR}/bin/badvpn-udpgw" /usr/bin/badvpn-udpgw
else
    # Fallback when the installer was obtained without the complete repository.
    BADVPN_TMP="$(mktemp)"
    if wget -qO "${BADVPN_TMP}" "https://raw.githubusercontent.com/brutalX-04/open-vpn/main/bin/badvpn-udpgw" \
        && [[ -s "${BADVPN_TMP}" ]]; then
        install -m 755 "${BADVPN_TMP}" /usr/bin/badvpn-udpgw
    fi
    rm -f "${BADVPN_TMP}"
fi

if [[ ! -x /usr/bin/badvpn-udpgw ]]; then
    echo -e "${RED}[ERROR] Binary BadVPN UDPGW tidak tersedia. Pastikan folder bin/ ikut terunduh.${NC}"
    exit 1
fi

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
if [[ ! -x /etc/openvpn/easy-rsa/easyrsa ]]; then
    cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/
fi
cd /etc/openvpn/easy-rsa/ || exit 1
if [[ ! -f pki/ca.crt ]]; then
    ./easyrsa --batch init-pki &>/dev/null
    ./easyrsa --batch build-ca nopass &>/dev/null
fi
if [[ ! -f pki/issued/server.crt ]]; then ./easyrsa --batch build-server-full server nopass &>/dev/null; fi
if [[ ! -f pki/crl.pem ]]; then ./easyrsa --batch gen-crl &>/dev/null; fi
if [[ ! -f /etc/openvpn/ta.key ]]; then openvpn --genkey secret /etc/openvpn/ta.key &>/dev/null; fi

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
script-security 2
management /run/openvpn/tcp.sock unix
cipher AES-256-CBC
auth SHA512
user nobody
group nogroup
persist-key
persist-tun
status /etc/openvpn/server/openvpn-tcp.log
status-version 3
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
script-security 2
management /run/openvpn/udp.sock unix
cipher AES-256-CBC
auth SHA512
user nobody
group nogroup
persist-key
persist-tun
explicit-exit-notify 1
status /etc/openvpn/server/openvpn-udp.log
status-version 3
verb 3
EOF

# Enable IP Forwarding
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn.conf
sysctl -p /etc/sysctl.d/99-openvpn.conf &>/dev/null

# IPTables Nat Rules for OpenVPN
NIC=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "${NIC}" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "${NIC}" -j MASQUERADE
iptables -t nat -C POSTROUTING -s 10.9.0.0/24 -o "${NIC}" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o "${NIC}" -j MASQUERADE

# Permit only the installed SSH/OpenVPN listeners and HTTP(S) front proxy.
# Insert before any terminal REJECT rule so the service ports are reachable.
allow_input_port() {
    local protocol="$1" port="$2" reject_line
    iptables -C INPUT -p "${protocol}" --dport "${port}" -m state --state NEW -j ACCEPT 2>/dev/null && return 0
    reject_line=$(iptables -L INPUT --line-numbers -n | awk '/REJECT/ {print $1; exit}')
    if [[ -n "${reject_line}" ]]; then
        iptables -I INPUT "${reject_line}" -p "${protocol}" --dport "${port}" -m state --state NEW -j ACCEPT
    else
        iptables -I INPUT 1 -p "${protocol}" --dport "${port}" -m state --state NEW -j ACCEPT
    fi
}
allow_input_port tcp 80
allow_input_port tcp 443
allow_input_port tcp 1194
allow_input_port udp 1194
netfilter-persistent save &>/dev/null

cat > /etc/systemd/system/vpn-openvpn-tcp.service <<'EOF'
[Unit]
Description=OpenVPN TCP server
After=network.target

[Service]
ExecStartPre=/usr/bin/install -d -m 0755 /run/openvpn
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
ExecStartPre=/usr/bin/install -d -m 0755 /run/openvpn
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

if [[ ! -f /etc/xray/config.json ]]; then
cat > /etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "api": { "tag": "api", "services": ["HandlerService", "StatsService"] },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1", "network": "tcp" },
      "tag": "api"
    },
    {
      "listen": "127.0.0.1",
      "port": 10001,
      "protocol": "vmess",
      "tag": "vmess-ws",
      "settings": { "clients": [] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess" } }
    },
    {
      "listen": "127.0.0.1",
      "port": 10002,
      "protocol": "vless",
      "tag": "vless-ws",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless" } }
    },
    {
      "listen": "127.0.0.1",
      "port": 10003,
      "protocol": "trojan",
      "tag": "trojan-ws",
      "settings": { "clients": [] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan-ws" } }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ],
  "routing": { "rules": [ { "type": "field", "inboundTag": ["api"], "outboundTag": "api" } ] }
}
EOF
fi

# Xray-install's unit defaults to /usr/local/etc/xray/config.json and
# User=nobody. The control plane owns /etc/xray/config.json, so point the unit
# at that same file and make it readable only by root and the Xray service's
# existing unprivileged group.
install -d -m 0755 /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/20-vpn-config.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
EOF
chown root:nogroup /etc/xray
chmod 0750 /etc/xray
chown root:nogroup /etc/xray/config.json
chmod 0640 /etc/xray/config.json
systemctl daemon-reload
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

# Shadow-utils needs a writable account lock file while the API creates or
# deletes SSH users. Keep it present so the systemd sandbox can allow the file
# without making all of /etc writable.
if [[ ! -e /etc/.pwd.lock ]]; then
    install -o root -g root -m 0600 /dev/null /etc/.pwd.lock
fi

cat > /etc/systemd/system/vpn-api.service <<'EOF'
[Unit]
Description=VPN HTTP API
After=network.target xray.service vpn-openvpn-tcp.service vpn-openvpn-udp.service

[Service]
Type=simple
User=root
WorkingDirectory=/etc/vpn
EnvironmentFile=/etc/vpn/api.env
Environment=PYTHONPATH=/etc/vpn
ExecStart=/etc/vpn/venv/bin/uvicorn api.main:app --host 127.0.0.1 --port 8088 --workers 1
Restart=on-failure
ProtectHome=true
PrivateTmp=true
# shadow-utils writes lock and temporary account files in /etc; ProtectSystem
# prevents useradd/usermod from functioning even with individual paths allowed.
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/vpn-session-guard.service <<'EOF'
[Unit]
Description=VPN per-account session guard
After=network.target vpn-openvpn-tcp.service vpn-openvpn-udp.service

[Service]
Type=simple
User=root
WorkingDirectory=/etc/vpn
Environment=PYTHONPATH=/etc/vpn
ExecStart=/etc/vpn/venv/bin/python -m vpnctl.guard
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=2
ProtectHome=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/etc/vpn /var/lib/vpn /run/vpn /run/openvpn /var/log/vpn
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/vpn-crl-refresh.service <<'EOF'
[Unit]
Description=Refresh OpenVPN certificate revocation list

[Service]
Type=oneshot
ExecStart=/etc/vpn/scripts/system/refresh-crl.sh
EOF

cat > /etc/systemd/system/vpn-crl-refresh.timer <<'EOF'
[Unit]
Description=Refresh OpenVPN CRL weekly

[Timer]
OnCalendar=weekly
Persistent=true
Unit=vpn-crl-refresh.service

[Install]
WantedBy=timers.target
EOF

systemctl disable --now vpn-session-limit.timer vpn-session-limit.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/vpn-session-limit.service /etc/systemd/system/vpn-session-limit.timer
rm -f /etc/cron.d/vpn-autokill
rm -f /usr/local/bin/vpn-tendang /usr/bin/vpn-tendang
systemctl daemon-reload
systemctl enable vpn-api.service vpn-session-guard.service >/dev/null
systemctl enable --now vpn-crl-refresh.timer >/dev/null

# ── Symlinks to /usr/bin for CLI Commands ─────────────────
ln -sf /etc/vpn/scripts/menu/main.sh /usr/bin/menu
ln -sf /etc/vpn/scripts/menu/menu-ssh.sh /usr/bin/menu-ssh
ln -sf /etc/vpn/scripts/menu/menu-xray.sh /usr/bin/menu-xray
ln -sf /etc/vpn/scripts/menu/menu-ovpn.sh /usr/bin/menu-ovpn
ln -sf /etc/vpn/scripts/system/status.sh /usr/bin/running
ln -sf /etc/vpn/scripts/system/status.sh /usr/bin/status
ln -sf /etc/vpn/scripts/system/restart.sh /usr/bin/restart-service
cat > /usr/local/bin/vpn-cli <<'EOF'
#!/bin/sh
export PYTHONPATH=/etc/vpn
exec /etc/vpn/venv/bin/python -m vpnctl.cli "$@"
EOF
chmod 755 /usr/local/bin/vpn-cli
ln -sf /usr/local/bin/vpn-cli /usr/bin/vpn-cli

PYTHONPATH=/etc/vpn /etc/vpn/venv/bin/python -m vpnctl.cli migrate >/var/log/vpn/migration.log 2>&1 || true

chmod +x /etc/vpn/lib/*.sh 2>/dev/null
chmod +x /etc/vpn/scripts/*/*.sh 2>/dev/null
chmod +x /etc/vpn/scripts/api/cli.py /etc/vpn/scripts/system/refresh-crl.sh 2>/dev/null
chmod +x /usr/bin/menu* /usr/bin/running /usr/bin/status /usr/bin/vpn-cli 2>/dev/null

# Apply updated service definitions and copied code on repeated installs too.
for unit in vpn-api.service vpn-session-guard.service; do
    if systemctl is-active --quiet "${unit}"; then
        systemctl restart "${unit}"
    else
        systemctl start "${unit}"
    fi
done

# Configure the Xray TLS/WebSocket client profile once Xray and the API are ready.
if [[ "${XRAY_PROXY_ENABLED}" == "1" ]]; then
    if bash "${SCRIPT_DIR}/scripts/system/configure-xray-proxy.sh" "${XRAY_PROXY_HOST}"; then
        :
    else
        echo -e "${YELLOW}[PERINGATAN] Setup profil Xray TLS/WebSocket gagal. Jalankan ulang setelah DNS A dan akses TCP 80/443 siap:${NC}"
        echo "sudo bash /etc/vpn/scripts/system/configure-xray-proxy.sh ${XRAY_PROXY_HOST}"
    fi
fi

clear
echo -e "${GREEN}"
echo "=========================================================="
echo "      INSTALASI AUTOSCRIPT SELESAI DENGAN SUKSES!         "
echo "=========================================================="
echo -e "${NC}"
echo -e "Ketik '${BWHITE}menu${NC}' untuk membuka Menu Utama."
echo -e "Gunakan '${BWHITE}vpn-cli${NC}' untuk operasi akun."
if [[ "${API_KEY_CREATED:-0}" == "1" ]]; then
    echo -e "API lokal aktif di 127.0.0.1:8088. API Key (simpan sekarang): ${BWHITE}${API_KEY}${NC}"
fi
if [[ "${PUBLIC_API_ENABLED}" == "1" ]]; then
    echo -e "API HTTPS tersedia di https://${PUBLIC_API_HOST}; backend tetap bind ke 127.0.0.1:8088."
else
    echo -e "API hanya tersedia lokal di 127.0.0.1:8088; jangan membuka akses eksternal tanpa reverse proxy HTTPS."
fi
echo ""
