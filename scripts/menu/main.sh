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
VMESS_COUNT=$(grep -c '"email"' /etc/xray/config.json 2>/dev/null || echo 0)
OVPN_TCP=$(grep "^CLIENT_LIST" /etc/openvpn/server/openvpn-tcp.log 2>/dev/null | wc -l)
OVPN_UDP=$(grep "^CLIENT_LIST" /etc/openvpn/server/openvpn-udp.log 2>/dev/null | wc -l)
TODAY_DATE=$(date +"%A, %d %B %Y | %H:%M WIB")

clear

echo -e "${BCYAN}"
echo "================================================="
echo "        SYSTEM AUTOSCRIPT VPN PREMIUM            "
echo "================================================="
echo -e "${NC}"

divider
echo -e "  ${BYELLOW}[ SERVER INFORMATION ]${NC}"
echo -e "  ${BWHITE}IP / Host ${NC}: ${CYAN}${MYIP:-N/A}${NC}   ${BWHITE}Domain${NC}: ${CYAN}${DOMAIN:-N/A}${NC}"
echo -e "  ${BWHITE}Uptime    ${NC}: ${UPTIME}   ${BWHITE}RAM${NC}: ${USED_RAM}/${TOTAL_RAM} MB   ${BWHITE}CPU${NC}: ${CPU}%"
echo -e "  ${BWHITE}Tanggal   ${NC}: ${TODAY_DATE}"
divider
echo -e "  ${BYELLOW}[ ACTIVE CONNECTIONS ]${NC}"
echo -e "  ${BWHITE}SSH User   ${NC}: ${BCYAN}${SSH_COUNT}${NC}   ${BWHITE}Xray${NC}: ${BCYAN}${VMESS_COUNT}${NC}"
echo -e "  ${BWHITE}OVPN TCP   ${NC}: ${BCYAN}${OVPN_TCP}${NC}   ${BWHITE}OVPN UDP${NC}: ${BPURPLE}${OVPN_UDP}${NC}"
divider

echo ""
echo -e "  ${BYELLOW}--- MENU LAYANAN -----------------------------${NC}"
echo ""
echo -e "  ${BCYAN}[1]${NC}  ${BWHITE}SSH${NC}          Create, Delete, Renew, List, Cek"
echo -e "  ${BCYAN}[2]${NC}  ${BWHITE}Vmess${NC}        WS TLS, non-TLS, gRPC"
echo -e "  ${BCYAN}[3]${NC}  ${BWHITE}Vless${NC}        WS TLS, non-TLS, gRPC"
echo -e "  ${BCYAN}[4]${NC}  ${BWHITE}Trojan${NC}       WS, gRPC"
echo -e "  ${BCYAN}[5]${NC}  ${BPURPLE}OpenVPN${NC}      TCP, UDP"
echo -e "  ${BCYAN}[6]${NC}  ${BWHITE}Status${NC}       Semua Service"
echo -e "  ${BCYAN}[7]${NC}  ${BWHITE}Restart${NC}      Restart Service"
echo -e "  ${BCYAN}[8]${NC}  ${BWHITE}Setting${NC}      AutoKill, Clear Cache"
echo -e "  ${BCYAN}[9]${NC}  ${BRED}Reboot${NC}       Restart VPS"
echo -e "  ${BCYAN}[x]${NC}  ${BWHITE}Exit${NC}"
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
    8) clear; menu-setting ;;
    9) clear; confirm "Yakin ingin reboot?" && reboot ;;
    x|X) exit 0 ;;
    *) warn "Pilihan tidak valid."; sleep 1; menu ;;
esac
