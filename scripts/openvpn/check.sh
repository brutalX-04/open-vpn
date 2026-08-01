#!/bin/bash
# ============================================================
#  openvpn/check.sh — Cek Koneksi Aktif OpenVPN
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

LOG_TCP="/etc/openvpn/server/openvpn-tcp.log"
LOG_UDP="/etc/openvpn/server/openvpn-udp.log"

clear
header "  CEK KONEKSI OpenVPN AKTIF  "

# ── TCP Connections ────────────────────────────────────────
section "OpenVPN TCP Aktif"
printf "\n  ${BWHITE}%-20s %-18s %-20s${NC}\n" "USERNAME" "IP ADDRESS" "CONNECTED SINCE"
divider

COUNT_TCP=0
if [[ -f "${LOG_TCP}" ]]; then
    while IFS=',' read -r _ USER CLIENT_IP _ _ _ _ SINCE _; do
        printf "  %-20s %-18s %-20s\n" "${USER}" "${CLIENT_IP}" "${SINCE}"
        (( COUNT_TCP++ ))
    done < <(grep "^CLIENT_LIST" "${LOG_TCP}" 2>/dev/null)
fi

[[ "${COUNT_TCP}" -eq 0 ]] && echo -e "  ${YELLOW}Tidak ada koneksi TCP aktif.${NC}"

# ── UDP Connections ────────────────────────────────────────
section "OpenVPN UDP Aktif"
printf "\n  ${BWHITE}%-20s %-18s %-20s${NC}\n" "USERNAME" "IP ADDRESS" "CONNECTED SINCE"
divider

COUNT_UDP=0
if [[ -f "${LOG_UDP}" ]]; then
    while IFS=',' read -r _ USER CLIENT_IP _ _ _ _ SINCE _; do
        printf "  %-20s %-18s %-20s\n" "${USER}" "${CLIENT_IP}" "${SINCE}"
        (( COUNT_UDP++ ))
    done < <(grep "^CLIENT_LIST" "${LOG_UDP}" 2>/dev/null)
fi

[[ "${COUNT_UDP}" -eq 0 ]] && echo -e "  ${YELLOW}Tidak ada koneksi UDP aktif.${NC}"

# ── Ringkasan ──────────────────────────────────────────────
divider
echo ""
echo -e "  ${BWHITE}TCP Aktif ${NC}: ${BCYAN}${COUNT_TCP}${NC}"
echo -e "  ${BWHITE}UDP Aktif ${NC}: ${BPURPLE}${COUNT_UDP}${NC}"
echo ""
press_any_key
menu-ovpn
