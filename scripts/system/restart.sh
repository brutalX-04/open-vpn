#!/bin/bash
# ============================================================
#  system/restart.sh — Restart Services VPN
#  Fix: tidak repeat header 11x, gunakan fungsi reusable
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

# Fungsi restart service
do_restart() {
    local label="${1}"
    shift
    info "Restarting ${label}..."
    for svc in "$@"; do
        if [[ "${svc}" == init:* ]]; then
            /etc/init.d/"${svc#init:}" restart &>/dev/null
        else
            systemctl restart "${svc}" &>/dev/null
        fi
    done
    success "${label} restarted."
}

show_menu() {
    clear
    header "  RESTART SERVICE  "
    echo ""
    echo -e "  ${BCYAN}[1]${NC}  Restart Semua Service"
    echo -e "  ${BCYAN}[2]${NC}  Restart OpenSSH"
    echo -e "  ${BCYAN}[3]${NC}  Restart Dropbear"
    echo -e "  ${BCYAN}[4]${NC}  Restart Stunnel4"
    echo -e "  ${BCYAN}[5]${NC}  Restart OpenVPN TCP"
    echo -e "  ${BCYAN}[6]${NC}  Restart OpenVPN UDP"
    echo -e "  ${BCYAN}[7]${NC}  Restart Nginx"
    echo -e "  ${BCYAN}[8]${NC}  Restart Xray"
    echo -e "  ${BCYAN}[9]${NC}  Restart Websocket"
    echo -e "  ${BCYAN}[10]${NC} Restart BadVPN UDPGW"
    echo -e "  ${BCYAN}[11]${NC} Restart Fail2Ban"
    echo ""
    echo -e "  ${BRED}[0]${NC}  Kembali ke Menu"
    divider
    read -rp "$(echo -e "  ${BYELLOW}Pilih [0-11]: ${NC}")" OPT
}

while true; do
    show_menu
    case "${OPT}" in
        1)
            do_restart "SSH"         init:ssh
            do_restart "Dropbear"    init:dropbear
            do_restart "Stunnel4"    init:stunnel4
            do_restart "OpenVPN TCP" vpn-openvpn-tcp
            do_restart "OpenVPN UDP" vpn-openvpn-udp
            do_restart "Nginx"       init:nginx
            do_restart "Xray"        xray xray.service
            do_restart "Websocket"   ws-stunnel.service ws-dropbear.service
            do_restart "Fail2Ban"    fail2ban
            # Restart BadVPN
            info "Restarting BadVPN UDPGW..."
            pkill badvpn-udpgw &>/dev/null
            sleep 0.5
            for PORT in 7100 7200 7300; do
                screen -dmS "badvpn-${PORT}" badvpn-udpgw --listen-addr "127.0.0.1:${PORT}" --max-clients 500
            done
            success "BadVPN UDPGW restarted (ports 7100-7300)."
            ;;
        2)  do_restart "OpenSSH"     init:ssh ;;
        3)  do_restart "Dropbear"    init:dropbear ;;
        4)  do_restart "Stunnel4"    init:stunnel4 ;;
        5)  do_restart "OpenVPN TCP" vpn-openvpn-tcp ;;
        6)  do_restart "OpenVPN UDP" vpn-openvpn-udp ;;
        7)  do_restart "Nginx"       init:nginx ;;
        8)  do_restart "Xray"        xray xray.service ;;
        9)  do_restart "Websocket"   ws-stunnel.service ws-dropbear.service ;;
        10)
            info "Restarting BadVPN UDPGW..."
            pkill badvpn-udpgw &>/dev/null
            sleep 0.5
            for PORT in 7100 7200 7300; do
                screen -dmS "badvpn-${PORT}" badvpn-udpgw --listen-addr "127.0.0.1:${PORT}" --max-clients 500
            done
            success "BadVPN UDPGW restarted."
            ;;
        11) do_restart "Fail2Ban"    fail2ban ;;
        0)  menu; exit 0 ;;
        *)  warn "Pilihan tidak valid!" ;;
    esac
    press_any_key
done
