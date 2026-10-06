#!/bin/bash
# Create OpenVPN UDP client through shared vpnctl library.
source /etc/vpn/lib/colors.sh
require_root
CLIENT_DIR=/etc/openvpn/clients
clear
header "  BUAT AKUN OpenVPN UDP  "
echo ""
echo -e "  ${BYELLOW}UDP Mode: Latency lebih rendah, cocok untuk game & streaming${NC}"
echo ""
read -rp "$(echo -e "  ${BCYAN}Username         : ${NC}")" USERNAME
read -rp "$(echo -e "  ${BCYAN}Masa Aktif (hari): ${NC}")" DAYS
echo ""
if [[ -z "${USERNAME}" || ! "${DAYS}" =~ ^[0-9]+$ ]]; then error "Username dan masa aktif harus valid!"; exit 1; fi
CREATE_JSON=$(/usr/bin/vpn-cli create --service ovpn-udp --user "${USERNAME}" --days "${DAYS}" 2>/dev/null) || { error "Gagal membuat akun. Periksa username dan service."; exit 1; }
META=$(echo "${CREATE_JSON}" | jq -r '.data.meta')
FILENAME=$(echo "${META}" | jq -r '.filename')
HOST=$(echo "${META}" | jq -r '.host')
PORT=$(echo "${META}" | jq -r '.port')
EXPIRE=$(echo "${CREATE_JSON}" | jq -r '.data.expires_at' | xargs -I{} date -u -d @{} +'%Y-%m-%d')
clear
header "  AKUN OpenVPN UDP BERHASIL DIBUAT  "
echo ""
echo -e "  ${BWHITE}Username    ${NC}: ${BGREEN}${USERNAME}${NC}"
echo -e "  ${BWHITE}Protokol    ${NC}: ${BPURPLE}UDP ⚡${NC}"
echo -e "  ${BWHITE}Server      ${NC}: ${HOST}"
echo -e "  ${BWHITE}Port        ${NC}: ${PORT}"
echo -e "  ${BWHITE}Expired     ${NC}: ${BGREEN}${EXPIRE}${NC}"
divider
echo -e "  ${BYELLOW}File config${NC}: ${CLIENT_DIR}/${FILENAME}"
echo -e "  ${CYAN}Download file tersebut ke perangkat client.${NC}"
echo ""
echo -e "  ${BYELLOW}Tip UDP${NC}: Jika jaringan tidak stabil, gunakan TCP sebagai backup."
divider
echo ""
press_any_key
menu-ovpn
