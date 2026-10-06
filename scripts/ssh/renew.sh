#!/bin/bash
source /etc/vpn/lib/colors.sh
require_root
clear
header "  PERPANJANG AKUN SSH  "
echo ""
read -rp "$(echo -e "  ${BCYAN}Username        : ${NC}")" USERNAME
echo ""
ROW=$(/usr/bin/vpn-cli list --service ssh 2>/dev/null | jq -c --arg u "${USERNAME}" '.data[] | select(.username==$u)' | head -1)
if [[ -z "${ROW}" ]]; then error "User '${USERNAME}' tidak ditemukan di registry!"; press_any_key; menu-ssh; exit 1; fi
CURRENT_EXP=$(echo "${ROW}" | jq -r '.expires_at')
echo -e "  ${BWHITE}Username          ${NC}: ${BCYAN}${USERNAME}${NC}"
echo -e "  ${BWHITE}Expired Saat Ini  ${NC}: ${BYELLOW}${CURRENT_EXP}${NC}"
echo ""
read -rp "$(echo -e "  ${BCYAN}Tambah Hari (1-30) : ${NC}")" DAYS
echo ""
NEW_ROW=$(/usr/bin/vpn-cli renew --service ssh --user "${USERNAME}" --days "${DAYS}" 2>/dev/null) || { error "Perpanjangan gagal. Masa aktif harus 1 sampai 30 hari."; exit 1; }
NEW_EXP=$(echo "${NEW_ROW}" | jq -r '.data.expires_at')
echo "[${NOW}] RENEW | ssh | user=${USERNAME} | +${DAYS}d" >> /var/log/vpn/ssh-users.log
clear
header "  AKUN SSH DIPERPANJANG  "
echo ""
echo -e "  ${BWHITE}Username     ${NC}: ${BGREEN}${USERNAME}${NC}"
echo -e "  ${BWHITE}Ditambah     ${NC}: ${BGREEN}+${DAYS} hari${NC}"
echo -e "  ${BWHITE}Expired Baru ${NC}: ${BGREEN}${NEW_EXP}${NC}"
echo ""
press_any_key
menu-ssh
