#!/bin/bash
# ============================================================
#  ssh/delete.sh — Hapus Akun SSH
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

clear
header "  HAPUS AKUN SSH  "
echo ""

read -rp "$(echo -e "  ${BCYAN}Username yang akan dihapus : ${NC}")" USERNAME
echo ""

# ── Validasi ───────────────────────────────────────────────
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

EXP=$(chage -l "${USERNAME}" 2>/dev/null | grep "Account expires" | awk -F': ' '{print $2}')
echo -e "  ${BWHITE}Username  ${NC}: ${BRED}${USERNAME}${NC}"
echo -e "  ${BWHITE}Expired   ${NC}: ${EXP}"
echo ""

if ! confirm "Yakin ingin menghapus user ini?"; then
    info "Dibatalkan."
    press_any_key
    menu-ssh
    exit 0
fi

# ── Kill sesi aktif dulu ───────────────────────────────────
pkill -u "${USERNAME}" 2>/dev/null
sleep 0.5

# ── Hapus user ─────────────────────────────────────────────
userdel --force "${USERNAME}" 2>/dev/null

if id "${USERNAME}" &>/dev/null; then
    error "Gagal menghapus user!"
    exit 1
fi

# ── Log ────────────────────────────────────────────────────
echo "[${NOW}] DELETE | user=${USERNAME}" >> /var/log/vpn/ssh-users.log

clear
header "  AKUN SSH DIHAPUS  "
echo ""
success "User '${USERNAME}' berhasil dihapus."
echo ""
press_any_key
menu-ssh
