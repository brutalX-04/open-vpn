#!/bin/bash
# ============================================================
#  menu/main.sh — Main Menu VPN Script (Clean & Professional)
# ============================================================
source /etc/vpn/lib/colors.sh

MYIP=$(get_config "IP")
DOMAIN=$(get_config "DOMAIN")
UPTIME=$(uptime -p | sed 's/up //')
TOTAL_RAM=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
USED_RAM=$(awk '/MemAvailable/ {total='"${TOTAL_RAM}"'; avail=int($2/1024); print total-avail}' /proc/meminfo)
CPU=$(top -bn1 | grep "Cpu(s)" | awk '{printf "%.0f", $2+$4}')

SSH_COUNT=$(awk -F: '$3 >= 1000 && $1 != "nobody" {c++} END {print c+0}' /etc/passwd)
VMESS_COUNT=$(grep -c '"email"' /etc/xray/config.json 2>/dev/null || true)
VMESS_COUNT=${VMESS_COUNT:-0}
OVPN_TCP=$(grep "^CLIENT_LIST" /etc/openvpn/server/openvpn-tcp.log 2>/dev/null | wc -l)
OVPN_UDP=$(grep "^CLIENT_LIST" /etc/openvpn/server/openvpn-udp.log 2>/dev/null | wc -l)
TODAY_DATE=$(date +"%A, %d %B %Y | %H:%M WIB")

clear
header "SYSTEM AUTOSCRIPT VPN PREMIUM"

section "INFORMASI SERVER"
printf "  ${BWHITE}%-10s${NC}: ${CYAN}%s${NC}\n" "IP / Host" "${MYIP:-N/A}"
printf "  ${BWHITE}%-10s${NC}: ${CYAN}%s${NC}\n" "Domain" "${DOMAIN:-N/A}"
printf "  ${BWHITE}%-10s${NC}: ${CYAN}%s${NC}\n" "Uptime" "${UPTIME}"
printf "  ${BWHITE}%-10s${NC}: ${CYAN}%s${NC}\n" "RAM" "${USED_RAM}/${TOTAL_RAM} MB"
printf "  ${BWHITE}%-10s${NC}: ${CYAN}%s${NC}\n" "CPU" "${CPU}%"
printf "  ${BWHITE}%-10s${NC}: ${CYAN}%s${NC}\n" "Tanggal" "${TODAY_DATE}"

section "KONEKSI AKTIF"
printf "  ${BWHITE}%-10s${NC}: ${CYAN}%s${NC}\n" "SSH User" "${SSH_COUNT}"
printf "  ${BWHITE}%-10s${NC}: ${CYAN}%s${NC}\n" "Xray User" "${VMESS_COUNT}"
printf "  ${BWHITE}%-10s${NC}: ${CYAN}%s${NC}\n" "OVPN TCP" "${OVPN_TCP}"
printf "  ${BWHITE}%-10s${NC}: ${CYAN}%s${NC}\n" "OVPN UDP" "${OVPN_UDP}"

section "MENU LAYANAN"
echo -e "  ${BCYAN}[1]${NC}  ${BWHITE}SSH${NC}          Kelola akun SSH"
echo -e "  ${BCYAN}[2]${NC}  ${BWHITE}VMess${NC}        WS TLS, non-TLS, gRPC"
echo -e "  ${BCYAN}[3]${NC}  ${BWHITE}VLess${NC}        WS TLS, non-TLS, gRPC"
echo -e "  ${BCYAN}[4]${NC}  ${BWHITE}Trojan${NC}       WS, gRPC"
echo -e "  ${BCYAN}[5]${NC}  ${BWHITE}OpenVPN${NC}      TCP dan UDP"
echo -e "  ${BCYAN}[6]${NC}  ${BWHITE}Status${NC}       Periksa seluruh service"
echo -e "  ${BCYAN}[7]${NC}  ${BWHITE}Restart${NC}      Restart service"
echo -e "  ${BCYAN}[8]${NC}  ${BWHITE}AutoKill${NC}     Atur batas sesi SSH"
echo -e "  ${BCYAN}[9]${NC}  ${BRED}Reboot${NC}       Restart VPS"
echo -e "  ${BCYAN}[x]${NC}  ${BWHITE}Keluar${NC}"
echo ""
divider
echo ""

read -rp "$(echo -e "  ${BYELLOW}> Pilih Menu : ${NC}")" OPT
echo ""

case "${OPT}" in
    1) clear; menu-ssh ;;
    2) clear; menu-xray vmess ;;
    3) clear; menu-xray vless ;;
    4) clear; menu-xray trojan ;;
    5) clear; menu-ovpn ;;
    6) clear; /etc/vpn/scripts/system/status.sh ;;
    7) clear; /etc/vpn/scripts/system/restart.sh ;;
    8) clear; /etc/vpn/scripts/system/autokill.sh ;;
    9) clear; confirm "Yakin ingin reboot?" && reboot ;;
    x|X) exit 0 ;;
    *) warn "Pilihan tidak valid."; sleep 1; menu ;;
esac
