#!/bin/bash
# ============================================================
#  openvpn/list.sh — Daftar Akun OpenVPN
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

CLIENT_DIR="/etc/openvpn/clients"
mkdir -p "${CLIENT_DIR}"

clear
header "  DAFTAR AKUN OpenVPN  "
echo ""
printf "  ${BWHITE}%-20s %-10s %-14s${NC}\n" "USERNAME" "PROTOKOL" "EXPIRED"
divider

COUNT=0
for OVPN_FILE in "${CLIENT_DIR}"/*.ovpn; do
    [[ ! -f "${OVPN_FILE}" ]] && continue
    FNAME=$(basename "${OVPN_FILE}" .ovpn)

    # Ambil username dan protokol dari nama file
    if [[ "${FNAME}" == *"-tcp" ]]; then
        UNAME="${FNAME%-tcp}"
        PROTO="${BCYAN}TCP${NC}"
    elif [[ "${FNAME}" == *"-udp" ]]; then
        UNAME="${FNAME%-udp}"
        PROTO="${BPURPLE}UDP${NC}"
    else
        UNAME="${FNAME}"
        PROTO="N/A"
    fi

    # Ambil expired dari komentar dalam file
    EXPIRE=$(grep "^# Expired" "${OVPN_FILE}" | awk '{print $4}')
    [[ -z "${EXPIRE}" ]] && EXPIRE="N/A"

    # Status expired
    if [[ "${EXPIRE}" != "N/A" ]]; then
        EXP_EPOCH=$(date -d "${EXPIRE}" +%s 2>/dev/null || echo 0)
        TODAY_EPOCH=$(date +%s)
        if [[ "${EXP_EPOCH}" -lt "${TODAY_EPOCH}" ]]; then
            EXPIRE_DISPLAY="${BRED}${EXPIRE} (EXPIRED)${NC}"
        else
            EXPIRE_DISPLAY="${BGREEN}${EXPIRE}${NC}"
        fi
    else
        EXPIRE_DISPLAY="${BYELLOW}N/A${NC}"
    fi

    printf "  %-20s %-19s %b\n" "${UNAME}" "$(echo -e "${PROTO}")" "${EXPIRE_DISPLAY}"
    (( COUNT++ ))
done

divider
echo ""
[[ "${COUNT}" -eq 0 ]] && echo -e "  ${YELLOW}Belum ada akun OpenVPN.${NC}"
echo -e "  ${BWHITE}Total${NC}: ${BCYAN}${COUNT} file config${NC}"
echo ""
press_any_key
menu-ovpn
