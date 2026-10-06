#!/bin/bash
# Show tunnel-capable OpenSSH/Dropbear user processes (not utmp sessions).
source /etc/vpn/lib/colors.sh
require_root
clear
header "  CEK KONEKSI AKTIF SSH  "
section "Sesi SSH Aktif"
printf "\n  ${BWHITE}%-8s %-18s %-24s${NC}\n" "PID" "USERNAME" "PROCESS"
divider
COUNT=0
while read -r PID ACCOUNT COMMAND; do
    [[ -z "${PID}" ]] && continue
    SESSION_USER=$(echo "${COMMAND}" | sed -nE 's/.*(sshd|dropbear):? ([a-z][a-z0-9_]{2,19})(@.*)?/\2/p')
    [[ -z "${SESSION_USER}" ]] && SESSION_USER="${ACCOUNT}"
    printf "  %-8s %-18s %-24s\n" "${PID}" "${SESSION_USER}" "${COMMAND:0:24}"
    COUNT=$((COUNT + 1))
done < <(ps -eo pid=,user=,args= | awk '$0 ~ /sshd:|dropbear:/ && $2 != "root" {print $1, $2, substr($0, index($0,$3))}')
[[ "${COUNT}" -eq 0 ]] && echo -e "  ${YELLOW}Tidak ada sesi SSH aktif.${NC}"
divider
echo ""
echo -e "  ${BWHITE}Total Sesi SSH      ${NC}: ${BCYAN}${COUNT}${NC}"
echo ""
press_any_key
menu-ssh
