#!/bin/bash
# ============================================================
#  ssh/check.sh — Cek Koneksi Aktif SSH
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

# Deteksi log file
LOG_FILE=""
[[ -f "/var/log/auth.log" ]]  && LOG_FILE="/var/log/auth.log"
[[ -f "/var/log/secure" ]]    && LOG_FILE="/var/log/secure"

clear
header "  CEK KONEKSI AKTIF SSH  "

# ── OpenSSH Aktif ──────────────────────────────────────────
section "OpenSSH Login Aktif"
printf "\n  ${BWHITE}%-8s %-16s %-20s %-12s${NC}\n" "PID" "USERNAME" "IP ADDRESS" "TERMINAL"
divider

FOUND_SSH=0
while IFS= read -r line; do
    PID=$(echo "${line}" | awk '{print $2}')
    USER=$(echo "${line}" | awk '{print $1}')
    TTY=$(echo "${line}" | awk '{print $6}')
    IP=$(echo "${line}" | awk '{print $5}' | tr -d '()')
    printf "  %-8s %-16s %-20s %-12s\n" "${PID:-?}" "${USER}" "${IP:-local}" "${TTY}"
    (( FOUND_SSH++ ))
done < <(who -u 2>/dev/null | grep -v "^$")

[[ "${FOUND_SSH}" -eq 0 ]] && echo -e "  ${YELLOW}Tidak ada sesi OpenSSH aktif.${NC}"

# ── Dropbear Aktif ─────────────────────────────────────────
section "Dropbear Login Aktif"
printf "\n  ${BWHITE}%-8s %-16s %-20s${NC}\n" "PID" "USERNAME" "IP ADDRESS"
divider

FOUND_DB=0
if [[ -n "${LOG_FILE}" ]]; then
    # Ambil PID dropbear yang sedang berjalan
    mapfile -t DB_PIDS < <(pgrep -x dropbear 2>/dev/null)
    for PID in "${DB_PIDS[@]}"; do
        DB_LINE=$(grep "dropbear\[${PID}\]" "${LOG_FILE}" 2>/dev/null | \
                  grep -i "Password auth succeeded" | tail -1)
        [[ -z "${DB_LINE}" ]] && continue
        DB_USER=$(echo "${DB_LINE}" | awk '{print $10}')
        DB_IP=$(echo "${DB_LINE}" | awk '{print $12}')
        printf "  %-8s %-16s %-20s\n" "${PID}" "${DB_USER}" "${DB_IP}"
        (( FOUND_DB++ ))
    done
fi

[[ "${FOUND_DB}" -eq 0 ]] && echo -e "  ${YELLOW}Tidak ada sesi Dropbear aktif.${NC}"

# ── Ringkasan ──────────────────────────────────────────────
divider
echo ""
echo -e "  ${BWHITE}Total Sesi SSH      ${NC}: ${BCYAN}${FOUND_SSH}${NC}"
echo -e "  ${BWHITE}Total Sesi Dropbear ${NC}: ${BCYAN}${FOUND_DB}${NC}"
echo ""
press_any_key
menu-ssh
