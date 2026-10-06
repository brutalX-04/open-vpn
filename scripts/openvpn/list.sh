#!/bin/bash
source /etc/vpn/lib/colors.sh
require_root
clear
header "  DAFTAR AKUN OpenVPN  "
echo ""
printf "  ${BWHITE}%-20s %-10s %-25s${NC}\n" "USERNAME" "PROTOKOL" "EXPIRED (UTC)"
divider
for SERVICE in ovpn-tcp ovpn-udp; do
    /usr/bin/vpn-cli list --service "${SERVICE}" 2>/dev/null | jq -r --arg s "${SERVICE}" '.data[] | "\(.username)\t\($s)\t\(.expires_at)"' 2>/dev/null | while IFS=$'\t' read -r UNAME PROTO EXPIRES; do
        printf "  %-20s %-10s %-25s\n" "${UNAME}" "${PROTO#ovpn-}" "${EXPIRES}"
    done
done
divider
echo ""
press_any_key
menu-ovpn
