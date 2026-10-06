#!/bin/bash
source /etc/vpn/lib/colors.sh
require_root
clear
header "  HAPUS AKUN OpenVPN  "
echo ""
read -rp "$(echo -e "  ${BCYAN}Username yang akan dihapus : ${NC}")" USERNAME
echo ""
FOUND=0
for SERVICE in ovpn-tcp ovpn-udp; do
    if /usr/bin/vpn-cli list --service "${SERVICE}" 2>/dev/null | jq -e --arg u "${USERNAME}" '.data[] | select(.username==$u)' >/dev/null; then FOUND=1; fi
done
if [[ "${FOUND}" -eq 0 ]]; then error "User '${USERNAME}' tidak ditemukan!"; press_any_key; menu-ovpn; exit 1; fi
echo -e "  ${BWHITE}Username ${NC}: ${BRED}${USERNAME}${NC}"
echo ""
if ! confirm "Yakin ingin menghapus semua akun OpenVPN untuk user ini?"; then info "Dibatalkan."; press_any_key; menu-ovpn; exit 0; fi
for SERVICE in ovpn-tcp ovpn-udp; do
    if /usr/bin/vpn-cli list --service "${SERVICE}" 2>/dev/null | jq -e --arg u "${USERNAME}" '.data[] | select(.username==$u)' >/dev/null; then
        /usr/bin/vpn-cli delete --service "${SERVICE}" --user "${USERNAME}" >/dev/null || { error "Gagal menghapus ${SERVICE}."; exit 1; }
    fi
done
echo "[${NOW}] DELETE | openvpn | user=${USERNAME}" >> /var/log/vpn/ovpn-users.log
clear
header "  AKUN OpenVPN DIHAPUS  "
echo ""
success "User '${USERNAME}' berhasil dihapus."
echo ""
press_any_key
menu-ovpn
