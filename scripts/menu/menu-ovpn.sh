#!/bin/bash
# ============================================================
#  menu/menu-ovpn.sh — OpenVPN Submenu (TCP & UDP)
# ============================================================
source /etc/vpn/lib/colors.sh

clear
header "  MENU OPENVPN (TCP & UDP)  "
echo ""
echo -e "  ${BCYAN}[1]${NC}  Buat Akun OpenVPN TCP"
echo -e "  ${BPURPLE}[2]${NC}  Buat Akun OpenVPN UDP (Low Latency)"
echo -e "  ${BCYAN}[3]${NC}  Hapus Akun OpenVPN"
echo -e "  ${BCYAN}[4]${NC}  Daftar Akun OpenVPN"
echo -e "  ${BCYAN}[5]${NC}  Cek Koneksi Aktif (TCP & UDP)"
echo ""
echo -e "  ${BRED}[0]${NC}  Kembali ke Menu Utama"
divider
echo ""
read -rp "$(echo -e "  ${BYELLOW}> Pilih : ${NC}")" OPT

case "${OPT}" in
    1) /etc/vpn/scripts/openvpn/create-tcp.sh ;;
    2) /etc/vpn/scripts/openvpn/create-udp.sh ;;
    3) /etc/vpn/scripts/openvpn/delete.sh ;;
    4) /etc/vpn/scripts/openvpn/list.sh ;;
    5) /etc/vpn/scripts/openvpn/check.sh ;;
    0) menu ;;
    *) warn "Pilihan tidak valid."; sleep 1; menu-ovpn ;;
esac
