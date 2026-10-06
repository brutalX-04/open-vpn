#!/bin/bash
source /etc/vpn/lib/colors.sh
require_root
clear
header "  HAPUS AKUN XRAY  "
echo ""
read -rp "$(echo -e "  ${BCYAN}Username yang akan dihapus : ${NC}")" USERNAME
echo ""
FOUND=0
for SERVICE in vmess vless trojan; do
    if /usr/bin/vpn-cli list --service "${SERVICE}" 2>/dev/null | jq -e --arg u "${USERNAME}" '.data[] | select(.username==$u)' >/dev/null; then FOUND=1; fi
done
if [[ "${FOUND}" -eq 0 ]]; then error "Username '${USERNAME}' tidak ditemukan di registry Xray!"; press_any_key; menu-xray; exit 1; fi
echo -e "  ${BRED}Akan menghapus akun Xray: ${USERNAME}${NC}"
echo ""
if ! confirm "Yakin ingin menghapus?"; then info "Dibatalkan."; press_any_key; menu-xray; exit 0; fi
for SERVICE in vmess vless trojan; do
    if /usr/bin/vpn-cli list --service "${SERVICE}" 2>/dev/null | jq -e --arg u "${USERNAME}" '.data[] | select(.username==$u)' >/dev/null; then
        /usr/bin/vpn-cli delete --service "${SERVICE}" --user "${USERNAME}" >/dev/null || { error "Gagal menghapus akun ${SERVICE}."; exit 1; }
    fi
done
echo "[${NOW}] DELETE | xray | user=${USERNAME}" >> /var/log/vpn/xray-users.log
clear
header "  AKUN XRAY DIHAPUS  "
echo ""
success "User '${USERNAME}' berhasil dihapus dari protokol Xray."
echo ""
press_any_key
menu-xray
