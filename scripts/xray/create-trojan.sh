#!/bin/bash
# Trojan account creation through vpnctl; unsupported links are not advertised.
source /etc/vpn/lib/colors.sh
require_root
clear
header "  BUAT AKUN TROJAN  "
echo ""
read -rp "$(echo -e "  ${BCYAN}Username        : ${NC}")" USERNAME
read -rp "$(echo -e "  ${BCYAN}Masa Aktif (hari): ${NC}")" DAYS
echo ""
CREATE_JSON=$(/usr/bin/vpn-cli create --service trojan --user "${USERNAME}" --days "${DAYS}" 2>/dev/null) || { error "Gagal membuat akun Trojan."; exit 1; }
PASSWORD=$(echo "${CREATE_JSON}" | jq -r '.data.meta.password')
EXPIRE=$(echo "${CREATE_JSON}" | jq -r '.data.expires_at' | xargs -I{} date -u -d @{} +'%Y-%m-%d %H:%M UTC')
clear
header "  AKUN TROJAN BERHASIL DIBUAT  "
echo ""
echo -e "  ${BWHITE}Username    ${NC}: ${BGREEN}${USERNAME}${NC}"
echo -e "  ${BWHITE}Password    ${NC}: ${CYAN}${PASSWORD}${NC}"
echo -e "  ${BWHITE}Expired     ${NC}: ${BGREEN}${EXPIRE}${NC}"
if CONNECTION_LINK=$(python3 /etc/vpn/scripts/xray/connection-link.py trojan "${USERNAME}" "${PASSWORD}" 2>/dev/null); then
    echo -e "  ${BWHITE}Trojan Link ${NC}: ${CYAN}${CONNECTION_LINK}${NC}"
else
    echo -e "  ${BYELLOW}Link belum tersedia: front-proxy TLS belum dikonfigurasi.${NC}"
fi
echo ""
press_any_key
menu-xray
