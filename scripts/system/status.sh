#!/bin/bash
# ============================================================
#  system/status.sh — Status Semua Service VPN
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

# Fungsi cek status service
svc_status() {
    local name="${1}"
    local service="${2}"
    local state
    state=$(systemctl is-active "${service}" 2>/dev/null)
    status_line "${name}" "${state}"
}

# Fungsi cek status init.d
initd_status() {
    local name="${1}"
    local service="${2}"
    local state
    state=$(/etc/init.d/"${service}" status 2>/dev/null | grep -i "Active:" | awk '{print $3}' | tr -d '()')
    status_line "${name}" "${state}"
}

# Ambil info sistem
MYIP=$(get_config "IP")
DOMAIN=$(get_config "DOMAIN")
UPTIME=$(uptime -p | sed 's/up //')
KERNEL=$(uname -r)
TOTAL_RAM=$(grep "MemTotal:" /proc/meminfo | awk '{print $2}')
USED_RAM=$(grep "MemAvailable:" /proc/meminfo | awk '{print $2}')
USED_RAM=$(( (TOTAL_RAM - USED_RAM) / 1024 ))
TOTAL_RAM=$(( TOTAL_RAM / 1024 ))
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}' | cut -d. -f1)

clear
header "  STATUS SISTEM VPN  "
echo ""

# ── Info Server ────────────────────────────────────────────
echo -e "  ${BCYAN}[ SERVER INFO ]${NC}"
echo -e "  ${BWHITE}IP / Host ${NC}: ${CYAN}${MYIP}${NC}"
echo -e "  ${BWHITE}Domain    ${NC}: ${CYAN}${DOMAIN}${NC}"
echo -e "  ${BWHITE}Uptime    ${NC}: ${UPTIME}"
echo -e "  ${BWHITE}Kernel    ${NC}: ${KERNEL}"
echo -e "  ${BWHITE}RAM       ${NC}: ${USED_RAM}MB / ${TOTAL_RAM}MB"
echo -e "  ${BWHITE}CPU       ${NC}: ${CPU_USAGE}%"
divider

# ── Service Status ─────────────────────────────────────────
echo -e "  ${BCYAN}[ CORE SERVICES ]${NC}"
svc_status  "SSH"             "ssh"
svc_status  "Dropbear"        "dropbear"
svc_status  "Stunnel4"        "stunnel4"
svc_status  "Nginx"           "nginx"
svc_status  "Fail2Ban"        "fail2ban"
svc_status  "Cron"            "cron"
echo ""
echo -e "  ${BCYAN}[ OPENVPN ]${NC}"
svc_status  "OpenVPN TCP"     "vpn-openvpn-tcp"
svc_status  "OpenVPN UDP"     "vpn-openvpn-udp"
echo ""
echo -e "  ${BCYAN}[ XRAY / PROXY ]${NC}"
svc_status  "Xray"            "xray"
svc_status  "WS Stunnel"      "ws-stunnel"
svc_status  "WS Dropbear"     "ws-dropbear"
echo ""
echo -e "  ${BCYAN}[ UDP GATEWAY ]${NC}"
BADVPN_COUNT=$(pgrep -c badvpn-udpgw 2>/dev/null || echo 0)
if [[ "${BADVPN_COUNT}" -gt 0 ]]; then
    printf "  ${BWHITE}%-28s${NC} ${BGREEN}[ RUNNING ]${NC} (${BADVPN_COUNT} instance)\n" "BadVPN UDPGW"
else
    printf "  ${BWHITE}%-28s${NC} ${BRED}[ STOPPED ]${NC}\n" "BadVPN UDPGW"
fi
divider

# ── Jumlah User ────────────────────────────────────────────
echo ""
echo -e "  ${BCYAN}[ USER AKTIFF ]${NC}"
SSH_COUNT=$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1}' /etc/passwd | wc -l)
OVPN_TCP_CONN=$(grep "^CLIENT_LIST" /etc/openvpn/server/openvpn-tcp.log 2>/dev/null | wc -l)
OVPN_UDP_CONN=$(grep "^CLIENT_LIST" /etc/openvpn/server/openvpn-udp.log 2>/dev/null | wc -l)
XRAY_COUNT=$(grep -c '"email"' /etc/xray/config.json 2>/dev/null || echo 0)

echo -e "  ${BWHITE}SSH Users      ${NC}: ${BCYAN}${SSH_COUNT}${NC}"
echo -e "  ${BWHITE}OpenVPN TCP    ${NC}: ${BCYAN}${OVPN_TCP_CONN} connected${NC}"
echo -e "  ${BWHITE}OpenVPN UDP    ${NC}: ${BPURPLE}${OVPN_UDP_CONN} connected${NC}"
echo -e "  ${BWHITE}Xray Accounts  ${NC}: ${BCYAN}${XRAY_COUNT}${NC}"
divider
echo ""
press_any_key
menu
