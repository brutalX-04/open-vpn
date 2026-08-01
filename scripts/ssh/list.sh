#!/bin/bash
# ============================================================
#  ssh/list.sh — Daftar Semua Akun SSH
#  Fix: tidak pakai loop O(n²) head/tail lagi
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

clear
header "  DAFTAR AKUN SSH  "
echo ""
printf "  ${BWHITE}%-18s %-14s %-12s %-6s${NC}\n" "USERNAME" "EXPIRED" "STATUS" "LOGIN"
divider

TODAY_EPOCH=$(date +%s)
COUNT=0
EXPIRED_COUNT=0

# ── Baca semua user (UID >= 1000, bukan nobody) ────────────
while IFS=: read -r UNAME _ UID _ _ _ _; do
    [[ "${UID}" -lt 1000 ]] && continue
    [[ "${UNAME}" == "nobody" ]] && continue

    # Expired date dari shadow (field 8 = hari sejak epoch)
    SHADOW_EXP=$(awk -F: -v u="${UNAME}" '$1==u{print $8}' /etc/shadow 2>/dev/null)

    if [[ -z "${SHADOW_EXP}" || "${SHADOW_EXP}" == "0" ]]; then
        EXP_STR="Selamanya"
        STATUS="AKTIF"
        STATUS_COLOR="${BGREEN}"
    else
        EXP_EPOCH=$(( SHADOW_EXP * 86400 ))
        EXP_STR=$(date -d "@${EXP_EPOCH}" +"%d-%m-%Y" 2>/dev/null || echo "?")
        if [[ "${EXP_EPOCH}" -lt "${TODAY_EPOCH}" ]]; then
            STATUS="EXPIRED"
            STATUS_COLOR="${BRED}"
            (( EXPIRED_COUNT++ ))
        else
            STATUS="AKTIF"
            STATUS_COLOR="${BGREEN}"
        fi
    fi

    # Cek lock status
    LOCK=$(passwd -S "${UNAME}" 2>/dev/null | awk '{print $2}')
    if [[ "${LOCK}" == "L" ]]; then
        STATUS="LOCKED"
        STATUS_COLOR="${BYELLOW}"
    fi

    # Hitung login aktif
    LOGIN_COUNT=$(who | awk -v u="${UNAME}" '$1==u' | wc -l)

    printf "  %-18s %-14s ${STATUS_COLOR}%-12s${NC} %-6s\n" \
        "${UNAME}" "${EXP_STR}" "${STATUS}" "${LOGIN_COUNT}"
    (( COUNT++ ))

done < /etc/passwd

divider
echo ""
echo -e "  ${BWHITE}Total User  ${NC}: ${BCYAN}${COUNT}${NC}"
echo -e "  ${BWHITE}Expired     ${NC}: ${BRED}${EXPIRED_COUNT}${NC}"
echo ""
press_any_key
menu-ssh
