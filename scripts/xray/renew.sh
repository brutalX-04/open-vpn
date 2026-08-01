#!/bin/bash
# ============================================================
#  xray/renew.sh — Perpanjang Masa Aktif Akun Xray
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

XRAY_CONFIG="/etc/xray/config.json"

clear
header "  PERPANJANG AKUN XRAY  "
echo ""

read -rp "$(echo -e "  ${BCYAN}Username         : ${NC}")" USERNAME
echo ""

# ── Validasi ───────────────────────────────────────────────
if [[ -z "${USERNAME}" ]]; then
    error "Username tidak boleh kosong!"
    exit 1
fi

if ! grep -q "\"email\": \"${USERNAME}\"" "${XRAY_CONFIG}" 2>/dev/null; then
    error "Username '${USERNAME}' tidak ditemukan!"
    press_any_key
    menu-xray
    exit 1
fi

# Ambil tanggal expired dari comment field
CURRENT_EXP=$(grep -o "\"comment\": \"${USERNAME} [0-9-]*\"" "${XRAY_CONFIG}" | head -1 | grep -oP '\d{4}-\d{2}-\d{2}')

echo -e "  ${BWHITE}Username         ${NC}: ${BCYAN}${USERNAME}${NC}"
echo -e "  ${BWHITE}Expired Saat Ini ${NC}: ${BYELLOW}${CURRENT_EXP:-tidak diketahui}${NC}"
echo ""

read -rp "$(echo -e "  ${BCYAN}Tambah Hari : ${NC}")" DAYS
echo ""

if ! [[ "${DAYS}" =~ ^[0-9]+$ ]]; then
    error "Jumlah hari harus berupa angka!"
    exit 1
fi

# ── Hitung expired baru ────────────────────────────────────
if [[ -n "${CURRENT_EXP}" ]]; then
    BASE_EPOCH=$(date -d "${CURRENT_EXP}" +%s 2>/dev/null || echo 0)
    TODAY_EPOCH=$(date +%s)
    [[ "${BASE_EPOCH}" -lt "${TODAY_EPOCH}" ]] && BASE_DATE="${TODAY}" || BASE_DATE="${CURRENT_EXP}"
else
    BASE_DATE="${TODAY}"
fi

NEW_EXP=$(date -d "${BASE_DATE} +${DAYS} days" +"%Y-%m-%d")

# ── Update comment field di config ─────────────────────────
cp "${XRAY_CONFIG}" "${XRAY_CONFIG}.bak"
if [[ -n "${CURRENT_EXP}" ]]; then
    sed -i "s|\"comment\": \"${USERNAME} ${CURRENT_EXP}\"|\"comment\": \"${USERNAME} ${NEW_EXP}\"|g" "${XRAY_CONFIG}"
else
    # Tambah comment jika belum ada
    sed -i "s|\"email\": \"${USERNAME}\"|\"email\": \"${USERNAME}\",\"comment\": \"${USERNAME} ${NEW_EXP}\"|g" "${XRAY_CONFIG}"
fi

systemctl restart xray &>/dev/null

# ── Log ────────────────────────────────────────────────────
echo "[${NOW}] RENEW | xray | user=${USERNAME} | +${DAYS}d | new_exp=${NEW_EXP}" >> /var/log/vpn/xray-users.log

# ── Tampilkan Hasil ────────────────────────────────────────
clear
header "  AKUN XRAY DIPERPANJANG  "
echo ""
echo -e "  ${BWHITE}Username     ${NC}: ${BGREEN}${USERNAME}${NC}"
echo -e "  ${BWHITE}Ditambah     ${NC}: ${BGREEN}+${DAYS} hari${NC}"
echo -e "  ${BWHITE}Expired Baru ${NC}: ${BGREEN}$(date -d "${NEW_EXP}" +"%d %B %Y")${NC}"
echo ""
press_any_key
menu-xray
