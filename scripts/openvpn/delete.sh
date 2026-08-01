#!/bin/bash
# ============================================================
#  openvpn/delete.sh — Hapus Akun OpenVPN (TCP/UDP)
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

OVPN_DIR="/etc/openvpn"
CLIENT_DIR="${OVPN_DIR}/clients"
CA_DIR="${OVPN_DIR}/easy-rsa"

clear
header "  HAPUS AKUN OpenVPN  "
echo ""

read -rp "$(echo -e "  ${BCYAN}Username yang akan dihapus : ${NC}")" USERNAME
echo ""

# ── Validasi ───────────────────────────────────────────────
if [[ -z "${USERNAME}" ]]; then
    error "Username tidak boleh kosong!"
    exit 1
fi

TCP_FILE="${CLIENT_DIR}/${USERNAME}-tcp.ovpn"
UDP_FILE="${CLIENT_DIR}/${USERNAME}-udp.ovpn"

if [[ ! -f "${TCP_FILE}" && ! -f "${UDP_FILE}" ]]; then
    error "User '${USERNAME}' tidak ditemukan!"
    press_any_key
    menu-ovpn
    exit 1
fi

echo -e "  ${BWHITE}Username ${NC}: ${BRED}${USERNAME}${NC}"
[[ -f "${TCP_FILE}" ]] && echo -e "  ${BWHITE}File TCP ${NC}: ${TCP_FILE}"
[[ -f "${UDP_FILE}" ]] && echo -e "  ${BWHITE}File UDP ${NC}: ${UDP_FILE}"
echo ""

if ! confirm "Yakin ingin menghapus semua akun OpenVPN untuk user ini?"; then
    info "Dibatalkan."
    press_any_key
    menu-ovpn
    exit 0
fi

# ── Revoke Certificate ─────────────────────────────────────
if [[ -f "${CA_DIR}/pki/issued/${USERNAME}.crt" ]]; then
    cd "${CA_DIR}" || exit 1
    ./easyrsa --batch revoke "${USERNAME}" &>/dev/null
    ./easyrsa gen-crl &>/dev/null
    cp "${CA_DIR}/pki/crl.pem" "${OVPN_DIR}/crl.pem"
    success "Sertifikat dicabut (revoked)."
fi

# ── Hapus file config ──────────────────────────────────────
rm -f "${TCP_FILE}" "${UDP_FILE}"

# ── Reload OpenVPN (apply CRL baru) ───────────────────────
systemctl restart vpn-openvpn-tcp vpn-openvpn-udp &>/dev/null

# ── Log ────────────────────────────────────────────────────
echo "[${NOW}] DELETE | ovpn | user=${USERNAME}" >> /var/log/vpn/ovpn-users.log

clear
header "  AKUN OpenVPN DIHAPUS  "
echo ""
success "User '${USERNAME}' berhasil dihapus."
echo ""
press_any_key
menu-ovpn
