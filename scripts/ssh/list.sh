#!/bin/bash
source /etc/vpn/lib/colors.sh
require_root
clear
header "  DAFTAR AKUN SSH  "
echo ""
printf "  ${BWHITE}%-18s %-25s %-12s %-6s${NC}\n" "USERNAME" "EXPIRED (UTC)" "STATUS" "LOGIN"
divider
ROWS=$(/usr/bin/vpn-cli list --service ssh 2>/dev/null)
COUNT=$(echo "${ROWS}" | jq '.data | length' 2>/dev/null || echo 0)
while IFS=$'\t' read -r UNAME EXPIRES; do
    [[ -z "${UNAME}" ]] && continue
    if [[ "${EXPIRES}" =~ ^[0-9]+$ ]]; then
        EXPIRES_EPOCH=${EXPIRES}
    else
        EXPIRES_EPOCH=$(date -u -d "${EXPIRES}" +%s 2>/dev/null || echo 0)
    fi
    EXPIRES_DISPLAY=$(date -u -d "@${EXPIRES_EPOCH}" +'%Y-%m-%d %H:%M' 2>/dev/null || echo "Tidak diketahui")
    if (( EXPIRES_EPOCH <= $(date -u +%s) )); then STATE="EXPIRED"; COLOR="${BRED}"; else STATE="AKTIF"; COLOR="${BGREEN}"; fi
    LOGIN=$(ps -eo args= | grep -F "sshd: ${UNAME}@" | grep -v grep | wc -l)
    printf "  %-18s %-25s ${COLOR}%-12s${NC} %-6s\n" "${UNAME}" "${EXPIRES_DISPLAY}" "${STATE}" "${LOGIN}"
done < <(echo "${ROWS}" | jq -r '.data[] | [.username,.expires_at] | @tsv' 2>/dev/null)
divider
echo ""
echo -e "  ${BWHITE}Total User  ${NC}: ${BCYAN}${COUNT}${NC}"
echo ""
press_any_key
menu-ssh
