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

if id "${USERNAME}" &>/dev/null; then
    error "Username '${USERNAME}' sudah ada!"
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
PORT_UDP=$(get_config "PORT_UDP")

# ── Buat User ──────────────────────────────────────────────
EXPIRE_DATE=$(date -d "+${DAYS} days" +"%Y-%m-%d")
useradd -e "${EXPIRE_DATE}" -s /bin/false -M "${USERNAME}" 2>/dev/null
echo -e "${PASSWORD}\n${PASSWORD}" | passwd "${USERNAME}" &>/dev/null

if ! id "${USERNAME}" &>/dev/null; then
    error "Gagal membuat user! Periksa permission."
    exit 1
fi

EXP_DISPLAY=$(date -d "${EXPIRE_DATE}" +"%d %B %Y")

# ── Tulis Log ──────────────────────────────────────────────
mkdir -p /var/log/vpn
LOG_LINE="[${NOW}] CREATE | user=${USERNAME} | exp=${EXPIRE_DATE}"
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
echo -e "  ${BWHITE}SSH-WS      ${NC}: ${PORT_SSHWS}"
echo -e "  ${BWHITE}SSL-WS      ${NC}: ${PORT_SSLWS}"
echo -e "  ${BWHITE}Stunnel     ${NC}: ${PORT_STN}"
echo -e "  ${BWHITE}SSH-UDP     ${NC}: 1-65535"
echo -e "  ${BWHITE}UDPGW       ${NC}: 7100-7300"
divider
echo -e "  ${BYELLOW}Payload WSS${NC}"
echo -e "  ${CYAN}GET wss://${DOMAIN}/ [protocol][crlf]Host: bug[crlf]Upgrade: websocket[crlf][crlf]${NC}"
divider
echo ""
press_any_key
menu-ssh
