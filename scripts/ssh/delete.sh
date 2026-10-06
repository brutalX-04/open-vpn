#!/bin/bash
source /etc/vpn/lib/colors.sh
require_root
clear
header "  HAPUS AKUN SSH  "
echo ""
read -rp "$(echo -e "  ${BCYAN}Username yang akan dihapus : ${NC}")" USERNAME
echo ""
ROW=$(/usr/bin/vpn-cli list --service ssh 2>/dev/null | jq -c --arg u "${USERNAME}" '.data[] | select(.username==$u)' | head -1)
if [[ -z "${ROW}" ]]; then error "User '${USERNAME}' tidak ditemukan di registry!"; press_any_key; menu-ssh; exit 1; fi
EXP=$(echo "${ROW}" | jq -r '.expires_at')
echo -e "  ${BWHITE}Username  ${NC}: ${BRED}${USERNAME}${NC}"
echo -e "  ${BWHITE}Expired   ${NC}: ${EXP}"
echo ""
if ! confirm "Yakin ingin menghapus user ini?"; then info "Dibatalkan."; press_any_key; menu-ssh; exit 0; fi
/usr/bin/vpn-cli delete --service ssh --user "${USERNAME}" >/dev/null || { error "Gagal menghapus akun."; exit 1; }
echo "[${NOW}] DELETE | ssh | user=${USERNAME}" >> /var/log/vpn/ssh-users.log
clear
header "  AKUN SSH DIHAPUS  "
echo ""
success "User '${USERNAME}' berhasil dihapus."
echo ""
press_any_key
menu-ssh
