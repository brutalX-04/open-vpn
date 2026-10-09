#!/bin/bash
# ============================================================
#  ssh/create.sh — Buat Akun SSH Baru
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

clear
header "  BUAT AKUN SSH  "
echo ""

# ── Baca Input ─────────────────────────────────────────────
read -rp "$(echo -e "  ${BCYAN}Username   : ${NC}")" USERNAME
read -rp "$(echo -e "  ${BCYAN}Password   : ${NC}")" PASSWORD
read -rp "$(echo -e "  ${BCYAN}Masa Aktif : ${NC}")" DAYS
echo ""

# ── Validasi ───────────────────────────────────────────────
if [[ -z "${USERNAME}" || -z "${PASSWORD}" || -z "${DAYS}" ]]; then
    error "Username, password, dan masa aktif wajib diisi!"
    exit 1
fi

if ! [[ "${DAYS}" =~ ^[0-9]+$ ]] || [[ "${DAYS}" -lt 1 ]]; then
    error "Masa aktif harus berupa angka positif!"
    exit 1
fi

# ── Baca Info Server ───────────────────────────────────────
DOMAIN=$(get_config "DOMAIN")
IP=$(get_config "IP")
PORT_SSH=$(get_config "PORT_SSH")
PORT_DB=$(get_config "PORT_DROPBEAR")
PORT_SSHWS=$(get_config "PORT_SSHWS")
PORT_SSLWS=$(get_config "PORT_SSLWS")
PORT_STN=$(get_config "PORT_STUNNEL")
PORT_UDPGW=$(get_config "PORT_UDPGW")
SSH_WS_ACTIVE=0
if systemctl is-active --quiet vpn-ssh-ws.service 2>/dev/null \
    && nginx -T 2>/dev/null | grep -Fq 'proxy_pass http://127.0.0.1:2222;'; then
    SSH_WS_ACTIVE=1
fi

# ── Buat User ──────────────────────────────────────────────
CREATE_JSON=$(printf '%s\n' "${PASSWORD}" | /usr/bin/vpn-cli create --service ssh --user "${USERNAME}" --days "${DAYS}" --password-stdin 2>/dev/null)
if [[ $? -ne 0 ]]; then
    error "Gagal membuat user! Pastikan username belum dipakai dan masa aktif valid."
    exit 1
fi
EXP_EPOCH=$(echo "${CREATE_JSON}" | jq -r '.data.expires_at')
EXP_DISPLAY=$(date -d "@${EXP_EPOCH}" +"%d %B %Y")

# ── Tulis Log ──────────────────────────────────────────────
mkdir -p /var/log/vpn
LOG_LINE="[${NOW}] CREATE | user=${USERNAME} | expiry_epoch=${EXP_EPOCH}"
echo "${LOG_LINE}" >> /var/log/vpn/ssh-users.log

# ── Tampilkan Hasil ────────────────────────────────────────
clear
header "  AKUN SSH BERHASIL DIBUAT  "
echo ""
echo -e "  ${BWHITE}Username    ${NC}: ${BGREEN}${USERNAME}${NC}"
echo -e "  ${BWHITE}Password    ${NC}: ${BGREEN}${PASSWORD}${NC}"
echo -e "  ${BWHITE}Expired     ${NC}: ${BGREEN}${EXP_DISPLAY}${NC}"
divider
echo -e "  ${BWHITE}IP / Host   ${NC}: ${BCYAN}${IP}${NC}"
echo -e "  ${BWHITE}Domain      ${NC}: ${BCYAN}${DOMAIN}${NC}"
echo -e "  ${BWHITE}OpenSSH     ${NC}: ${PORT_SSH}"
echo -e "  ${BWHITE}Dropbear    ${NC}: ${PORT_DB}"
if [[ "${SSH_WS_ACTIVE}" == "1" ]]; then
    echo -e "  ${BWHITE}SSH-WS      ${NC}: ${PORT_SSHWS}"
    echo -e "  ${BWHITE}WSS         ${NC}: ${PORT_SSLWS}"
else
    echo -e "  ${BWHITE}SSH-WS/WSS  ${NC}: belum aktif (butuh konfigurasi domain TLS/WebSocket)"
fi
if systemctl is-active --quiet stunnel4.service 2>/dev/null; then
    echo -e "  ${BWHITE}Stunnel     ${NC}: ${PORT_STN}"
else
    echo -e "  ${BWHITE}Stunnel     ${NC}: nonaktif"
fi
echo -e "  ${BWHITE}UDP via SSH ${NC}: UDPGW ${PORT_UDPGW} (loopback, lewat tunnel SSH)"
divider
echo -e "  ${BYELLOW}Payload WebSocket${NC}"
if [[ "${SSH_WS_ACTIVE}" == "1" ]]; then
    echo -e "  ${CYAN}GET / HTTP/1.1[crlf]Host: ${DOMAIN}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]${NC}"
    echo -e "  ${BWHITE}Port 80: WS; port 443: WSS/TLS dengan SNI ${DOMAIN}.${NC}"
fi
divider
echo ""
press_any_key
menu-ssh
