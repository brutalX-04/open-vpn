#!/bin/bash
# ============================================================
#  ssh/renew.sh — Perpanjang Masa Aktif Akun SSH
#  Fix: renew tidak mengubah password (bug di old script)
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

clear
header "  PERPANJANG AKUN SSH  "
echo ""

read -rp "$(echo -e "  ${BCYAN}Username        : ${NC}")" USERNAME
echo ""

# ── Validasi User ──────────────────────────────────────────
if [[ -z "${USERNAME}" ]]; then
    error "Username tidak boleh kosong!"
    exit 1
fi

if ! id "${USERNAME}" &>/dev/null; then
    error "User '${USERNAME}' tidak ditemukan!"
    press_any_key
    menu-ssh
    exit 1
fi

# ── Tampilkan info sekarang ────────────────────────────────
CURRENT_EXP=$(chage -l "${USERNAME}" 2>/dev/null | grep "Account expires" | awk -F': ' '{print $2}')
echo -e "  ${BWHITE}Username     ${NC}: ${BCYAN}${USERNAME}${NC}"
echo -e "  ${BWHITE}Expired Saat Ini ${NC}: ${BYELLOW}${CURRENT_EXP}${NC}"
echo ""

read -rp "$(echo -e "  ${BCYAN}Tambah Hari (dari sekarang) : ${NC}")" DAYS
echo ""

# ── Validasi Hari ──────────────────────────────────────────
if ! [[ "${DAYS}" =~ ^[0-9]+$ ]] || [[ "${DAYS}" -lt 1 ]]; then
    error "Jumlah hari harus berupa angka positif!"
    exit 1
fi

# ── Hitung expired baru ────────────────────────────────────
# Jika saat ini sudah expired, tambah dari hari ini
# Jika masih aktif, tambah dari tanggal expired sekarang
if [[ "${CURRENT_EXP}" == "never" || "${CURRENT_EXP}" == "tidak pernah" ]]; then
    BASE_DATE="${TODAY}"
else
    BASE_EPOCH=$(date -d "${CURRENT_EXP}" +%s 2>/dev/null || echo 0)
    TODAY_EPOCH=$(date +%s)
    if [[ "${BASE_EPOCH}" -lt "${TODAY_EPOCH}" ]]; then
        BASE_DATE="${TODAY}"
    else
        BASE_DATE="${CURRENT_EXP}"
    fi
fi

NEW_EXP=$(date -d "${BASE_DATE} +${DAYS} days" +"%Y-%m-%d")
NEW_EXP_DISPLAY=$(date -d "${NEW_EXP}" +"%d %B %Y")

# ── Update expired ─────────────────────────────────────────
passwd -u "${USERNAME}" &>/dev/null
usermod -e "${NEW_EXP}" "${USERNAME}"

# ── Log ────────────────────────────────────────────────────
echo "[${NOW}] RENEW | user=${USERNAME} | +${DAYS}d | new_exp=${NEW_EXP}" >> /var/log/vpn/ssh-users.log

# ── Tampilkan Hasil ────────────────────────────────────────
clear
header "  AKUN SSH DIPERPANJANG  "
echo ""
echo -e "  ${BWHITE}Username    ${NC}: ${BGREEN}${USERNAME}${NC}"
echo -e "  ${BWHITE}Ditambah    ${NC}: ${BGREEN}+${DAYS} hari${NC}"
echo -e "  ${BWHITE}Expired Baru${NC}: ${BGREEN}${NEW_EXP_DISPLAY}${NC}"
echo ""
press_any_key
menu-ssh
