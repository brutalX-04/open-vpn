#!/bin/bash
# ============================================================
#  menu/menu-xray.sh — Xray Submenu (Vmess / Vless / Trojan)
#  Dipanggil dengan: menu-xray [vmess|vless|trojan]
# ============================================================
source /etc/vpn/lib/colors.sh

PROTO="${1:-vmess}"

case "${PROTO}" in
    vmess)  TITLE="VMESS" ;;
    vless)  TITLE="VLESS" ;;
    trojan) TITLE="TROJAN" ;;
    *)      TITLE="XRAY" ;;
esac

clear
header "  MENU ${TITLE}  "
echo ""
echo -e "  ${BCYAN}[1]${NC}  Buat Akun ${TITLE}"
echo -e "  ${BCYAN}[2]${NC}  Hapus Akun Xray"
echo -e "  ${BCYAN}[3]${NC}  Perpanjang Akun Xray"
echo -e "  ${BCYAN}[4]${NC}  Daftar Akun Xray"
echo ""
echo -e "  ${BRED}[0]${NC}  Kembali ke Menu Utama"
divider
echo ""
read -rp "$(echo -e "  ${BYELLOW}▶ Pilih : ${NC}")" OPT

case "${OPT}" in
    1) /etc/vpn/scripts/xray/create-${PROTO}.sh ;;
    2) /etc/vpn/scripts/xray/delete.sh ;;
    3) /etc/vpn/scripts/xray/renew.sh ;;
    4) /etc/vpn/scripts/xray/list.sh ;;
    0) menu ;;
    *) warn "Pilihan tidak valid."; sleep 1; menu-xray "${PROTO}" ;;
esac
