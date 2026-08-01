#!/bin/bash
# ============================================================
#  system/autokill.sh — Konfigurasi Auto-Kill Multi-Login
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

CRON_FILE="/etc/cron.d/vpn-autokill"

show_status() {
    if [[ -f "${CRON_FILE}" ]]; then
        INTERVAL=$(grep -v "^#" "${CRON_FILE}" | awk '{print $1}' | grep -oP '\d+')
        MAX=$(grep -v "^#" "${CRON_FILE}" | awk '{print $NF}')
        echo -e "  ${BWHITE}Status   ${NC}: ${BGREEN}● AKTIF${NC}"
        echo -e "  ${BWHITE}Interval ${NC}: ${BYELLOW}Setiap ${INTERVAL} menit${NC}"
        echo -e "  ${BWHITE}Max Login${NC}: ${BYELLOW}${MAX} sesi${NC}"
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
    1) INTERVAL="*/5"  ;;
    2) INTERVAL="*/10" ;;
    3) INTERVAL="*/15" ;;
    4)
        rm -f "${CRON_FILE}"
        systemctl reload cron &>/dev/null
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

# ── Tulis cron ─────────────────────────────────────────────
cat > "${CRON_FILE}" <<EOF
# VPN AutoKill Multi-Login
# Generated: ${NOW}
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
${INTERVAL} * * * * root /usr/bin/vpn-tendang ${MAX}
EOF

systemctl reload cron &>/dev/null

# ── Tampilkan Hasil ────────────────────────────────────────
clear
header "  AUTO-KILL DIKONFIGURASI  "
echo ""
show_status
echo ""
press_any_key
menu
