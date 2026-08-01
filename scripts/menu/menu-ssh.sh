#!/bin/bash
# ============================================================
#  menu/menu-ssh.sh — SSH Submenu
# ============================================================
source /etc/vpn/lib/colors.sh

clear
header "  MENU SSH  "
echo ""
echo -e "  ${BCYAN}[1]${NC}  Buat Akun SSH"
echo -e "  ${BCYAN}[2]${NC}  Hapus Akun SSH"
echo -e "  ${BCYAN}[3]${NC}  Perpanjang Akun SSH"
echo -e "  ${BCYAN}[4]${NC}  Daftar Akun SSH"
echo -e "  ${BCYAN}[5]${NC}  Cek Koneksi Aktif"
echo ""
echo -e "  ${BRED}[0]${NC}  Kembali ke Menu Utama"
divider
echo ""
read -rp "$(echo -e "  ${BYELLOW}▶ Pilih : ${NC}")" OPT

case "${OPT}" in
    1) /etc/vpn/scripts/ssh/create.sh ;;
    2) /etc/vpn/scripts/ssh/delete.sh ;;
    3) /etc/vpn/scripts/ssh/renew.sh ;;
    4) /etc/vpn/scripts/ssh/list.sh ;;
    5) /etc/vpn/scripts/ssh/check.sh ;;
    0) menu ;;
    *) warn "Pilihan tidak valid."; sleep 1; menu-ssh ;;
esac
