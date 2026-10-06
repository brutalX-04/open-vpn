#!/bin/bash
source /etc/vpn/lib/colors.sh
require_root
clear
header "  PERPANJANG AKUN XRAY  "
echo ""
read -rp "$(echo -e "  ${BCYAN}Username         : ${NC}")" USERNAME
echo ""
read -rp "$(echo -e "  ${BCYAN}Tambah Hari (1-30): ${NC}")" DAYS
echo ""
if ! [[ "${DAYS}" =~ ^[0-9]+$ ]] || [[ "${DAYS}" -lt 1 || "${DAYS}" -gt 30 ]]; then error "Masa aktif harus 1 sampai 30 hari."; exit 1; fi
RENEWED=0
NEW_EXP=""
for SERVICE in vmess vless trojan; do
    if /usr/bin/vpn-cli list --service "${SERVICE}" 2>/dev/null | jq -e --arg u "${USERNAME}" '.data[] | select(.username==$u)' >/dev/null; then
        RESULT=$(/usr/bin/vpn-cli renew --service "${SERVICE}" --user "${USERNAME}" --days "${DAYS}" 2>/dev/null) || { error "Gagal memperpanjang ${SERVICE}."; exit 1; }
        NEW_EXP=$(echo "${RESULT}" | jq -r '.data.expires_at')
        RENEWED=$((RENEWED + 1))
    fi
done
if [[ "${RENEWED}" -eq 0 ]]; then error "Username tidak ditemukan."; exit 1; fi
echo "[${NOW}] RENEW | xray | user=${USERNAME} | +${DAYS}d" >> /var/log/vpn/xray-users.log
clear
header "  AKUN XRAY DIPERPANJANG  "
echo ""
echo -e "  ${BWHITE}Username     ${NC}: ${BGREEN}${USERNAME}${NC}"
echo -e "  ${BWHITE}Ditambah     ${NC}: ${BGREEN}+${DAYS} hari${NC}"
echo -e "  ${BWHITE}Expired Baru ${NC}: ${BGREEN}${NEW_EXP}${NC}"
echo ""
press_any_key
menu-xray
