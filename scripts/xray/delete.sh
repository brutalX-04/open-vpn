#!/bin/bash
# ============================================================
#  xray/delete.sh — Hapus Akun Xray (Vmess / Vless / Trojan)
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

XRAY_CONFIG="/etc/xray/config.json"

clear
header "  HAPUS AKUN XRAY  "
echo ""

read -rp "$(echo -e "  ${BCYAN}Username yang akan dihapus : ${NC}")" USERNAME
echo ""

# ── Validasi ───────────────────────────────────────────────
if [[ -z "${USERNAME}" ]]; then
    error "Username tidak boleh kosong!"
    exit 1
fi

if ! grep -q "\"email\": \"${USERNAME}\"" "${XRAY_CONFIG}" 2>/dev/null; then
    error "Username '${USERNAME}' tidak ditemukan di Xray!"
    press_any_key
    menu-xray
    exit 1
fi

echo -e "  ${BRED}Akan menghapus semua akun Xray dengan email: ${USERNAME}${NC}"
echo ""

if ! confirm "Yakin ingin menghapus?"; then
    info "Dibatalkan."
    press_any_key
    menu-xray
    exit 0
fi

# ── Backup config ──────────────────────────────────────────
cp "${XRAY_CONFIG}" "${XRAY_CONFIG}.bak"

# ── Hapus entry menggunakan python3 (lebih aman dari sed untuk JSON) ──
python3 - <<PYEOF
import json, sys

config_file = "${XRAY_CONFIG}"
username = "${USERNAME}"

with open(config_file, 'r') as f:
    content = f.read()

with open(config_file, 'r') as f:
    config = json.load(f)

inbounds = config.get('inbounds', [])
removed = 0

for inbound in inbounds:
    settings = inbound.get('settings', {})
    clients = settings.get('clients', [])
    original_len = len(clients)
    settings['clients'] = [c for c in clients if c.get('email') != username and c.get('password') and c.get('email') != username]
    # Handle both vmess (email) and trojan (password + email)
    settings['clients'] = [c for c in clients if c.get('email', '') != username]
    removed += original_len - len(settings['clients'])

with open(config_file, 'w') as f:
    json.dump(config, f, indent=2)

print(f"Removed {removed} client(s) with email '{username}'")
PYEOF

systemctl restart xray &>/dev/null

# ── Log ────────────────────────────────────────────────────
echo "[${NOW}] DELETE | xray | user=${USERNAME}" >> /var/log/vpn/xray-users.log

clear
header "  AKUN XRAY DIHAPUS  "
echo ""
success "User '${USERNAME}' berhasil dihapus dari semua protokol Xray."
echo ""
press_any_key
menu-xray
