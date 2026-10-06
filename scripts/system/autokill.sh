#!/bin/bash
# ============================================================
#  system/autokill.sh — Konfigurasi Auto-Kill Multi-Login
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

LIMITS_FILE="/etc/vpn/limits.conf"

show_status() {
    if [[ -f "${LIMITS_FILE}" ]]; then
        INTERVAL=$(awk -F= '$1=="INTERVAL"{print $2}' "${LIMITS_FILE}")
        MAX=$(awk -F= '$1=="MAX_SESSIONS"{print $2}' "${LIMITS_FILE}")
        echo -e "  ${BWHITE}Status   ${NC}: ${BGREEN}● AKTIF${NC}"
        echo -e "  ${BWHITE}Interval ${NC}: ${BYELLOW}Setiap ${INTERVAL:-7} detik${NC}"
        echo -e "  ${BWHITE}Max Login${NC}: ${BYELLOW}${MAX:-1} sesi${NC}"
    else
        echo -e "  ${BWHITE}Status   ${NC}: ${BRED}● TIDAK AKTIF${NC}"
    fi
}

clear
header "  AUTO-KILL MULTI-LOGIN  "
echo ""
show_status
echo ""
divider
echo -e "  ${BCYAN}[1]${NC}  AutoKill setiap 5 menit"
echo -e "  ${BCYAN}[2]${NC}  AutoKill setiap 10 menit"
echo -e "  ${BCYAN}[3]${NC}  AutoKill setiap 15 menit"
echo -e "  ${BRED}[4]${NC}  Matikan AutoKill"
echo -e "  ${BYELLOW}[0]${NC}  Kembali"
divider
echo ""
read -rp "$(echo -e "  ${BCYAN}Pilih [0-4]: ${NC}")" OPT

if [[ "${OPT}" =~ ^[123]$ ]]; then
    echo ""
    read -rp "$(echo -e "  ${BCYAN}Maksimum sesi bersamaan per user: ${NC}")" MAX
    if ! [[ "${MAX}" =~ ^[0-9]+$ ]] || [[ "${MAX}" -lt 1 ]]; then
        error "Input tidak valid!"
        exit 1
    fi
fi

case "${OPT}" in
    1) INTERVAL=5 ;;
    2) INTERVAL=10 ;;
    3) INTERVAL=15 ;;
    4)
        rm -f "${LIMITS_FILE}"
        systemctl kill -s HUP vpn-session-guard &>/dev/null || true
        clear
        header "  AUTO-KILL DIMATIKAN  "
        success "AutoKill telah dinonaktifkan."
        press_any_key
        menu
        exit 0
        ;;
    0) menu; exit 0 ;;
    *) error "Pilihan tidak valid!"; exit 1 ;;
esac

cat > "${LIMITS_FILE}" <<EOF
MAX_SESSIONS=${MAX}
INTERVAL=${INTERVAL}
EOF
chmod 600 "${LIMITS_FILE}"
systemctl kill -s HUP vpn-session-guard &>/dev/null || true

clear
header "  AUTO-KILL DIKONFIGURASI  "
echo ""
show_status
echo ""
press_any_key
menu
