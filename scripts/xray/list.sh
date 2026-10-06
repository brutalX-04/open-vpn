#!/bin/bash
source /etc/vpn/lib/colors.sh
require_root
clear
header "  DAFTAR AKUN XRAY  "
echo ""
printf "  ${BWHITE}%-18s %-12s %-25s${NC}\n" "USERNAME" "PROTOKOL" "EXPIRED (UTC)"
divider
for SERVICE in vmess vless trojan; do
    /usr/bin/vpn-cli list --service "${SERVICE}" 2>/dev/null | jq -r --arg s "${SERVICE}" '.data[] | "\(.username)\t\($s)\t\(.expires_at)"' 2>/dev/null | while IFS=$'\t' read -r UNAME PROTO EXPIRES; do
        printf "  %-18s %-12s %-25s\n" "${UNAME}" "${PROTO}" "${EXPIRES}"
    done
done
divider
echo ""
press_any_key
menu-xray
