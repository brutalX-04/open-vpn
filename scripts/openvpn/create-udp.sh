#!/bin/bash
# ============================================================
#  openvpn/create-udp.sh — Buat Akun OpenVPN UDP
#  UDP lebih cepat (lower latency) untuk gaming & streaming
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

OVPN_DIR="/etc/openvpn"
CLIENT_DIR="${OVPN_DIR}/clients"
CA_DIR="${OVPN_DIR}/easy-rsa"

clear
header "  BUAT AKUN OpenVPN UDP  "
echo ""
echo -e "  ${BYELLOW}UDP Mode: Latency lebih rendah, cocok untuk game & streaming${NC}"
echo ""

read -rp "$(echo -e "  ${BCYAN}Username         : ${NC}")" USERNAME
read -rp "$(echo -e "  ${BCYAN}Masa Aktif (hari): ${NC}")" DAYS
echo ""

# ── Validasi ───────────────────────────────────────────────
if [[ -z "${USERNAME}" || -z "${DAYS}" ]]; then
    error "Username dan masa aktif wajib diisi!"
    exit 1
fi

if ! [[ "${DAYS}" =~ ^[0-9]+$ ]]; then
    error "Masa aktif harus berupa angka!"
    exit 1
fi

if [[ -f "${CLIENT_DIR}/${USERNAME}-udp.ovpn" ]]; then
    error "Username '${USERNAME}' sudah ada untuk UDP!"
    exit 1
fi

# ── Cek server UDP aktif ───────────────────────────────────
if ! systemctl is-active --quiet vpn-openvpn-udp 2>/dev/null; then
    warn "OpenVPN UDP service belum aktif!"
    warn "Jalankan: systemctl start vpn-openvpn-udp"
fi

# ── Generate Client Certificate ────────────────────────────
info "Membuat sertifikat untuk ${USERNAME} (UDP)..."
EXPIRE=$(date -d "+${DAYS} days" +"%Y-%m-%d")
IP=$(get_config "IP")
PORT_UDP=$(get_config "PORT_OVPN_UDP")
[[ -z "${PORT_UDP}" ]] && PORT_UDP="1194"

cd "${CA_DIR}" || { error "Easy-RSA dir tidak ditemukan!"; exit 1; }

# Generate cert hanya jika belum ada (bisa share cert dengan TCP)
if [[ ! -f "${CA_DIR}/pki/issued/${USERNAME}.crt" ]]; then
    EASYRSA_CERT_EXPIRE="${DAYS}" ./easyrsa --batch build-client-full "${USERNAME}" nopass &>/dev/null
fi

mkdir -p "${CLIENT_DIR}"

# ── Generate .ovpn file (UDP) ──────────────────────────────
cat > "${CLIENT_DIR}/${USERNAME}-udp.ovpn" <<EOF
# OpenVPN UDP Client Config
# Username  : ${USERNAME}
# Expired   : ${EXPIRE}
# Generated : ${NOW}
# Protocol  : UDP (Lower latency, faster)

client
dev tun
proto udp
remote ${IP} ${PORT_UDP}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
cipher AES-256-CBC
compress lz4-v2
key-direction 1
; UDP specific: explicit-exit-notify memberitahu server saat client disconnect
explicit-exit-notify 1
verb 3

<ca>
$(cat "${CA_DIR}/pki/ca.crt")
</ca>
<cert>
$(sed -ne '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "${CA_DIR}/pki/issued/${USERNAME}.crt")
</cert>
<key>
$(cat "${CA_DIR}/pki/private/${USERNAME}.key")
</key>
<tls-auth>
$(cat "${OVPN_DIR}/ta.key")
</tls-auth>
EOF

# ── Log ────────────────────────────────────────────────────
mkdir -p /var/log/vpn
echo "[${NOW}] CREATE | ovpn-udp | user=${USERNAME} | exp=${EXPIRE}" >> /var/log/vpn/ovpn-users.log

# ── Tampilkan Hasil ────────────────────────────────────────
clear
header "  AKUN OpenVPN UDP BERHASIL DIBUAT  "
echo ""
echo -e "  ${BWHITE}Username    ${NC}: ${BGREEN}${USERNAME}${NC}"
echo -e "  ${BWHITE}Protokol    ${NC}: ${BPURPLE}UDP ⚡${NC}"
echo -e "  ${BWHITE}Server      ${NC}: ${IP}"
echo -e "  ${BWHITE}Port        ${NC}: ${PORT_UDP}"
echo -e "  ${BWHITE}Expired     ${NC}: ${BGREEN}$(date -d "${EXPIRE}" +"%d %B %Y")${NC}"
divider
echo -e "  ${BYELLOW}File config${NC}: ${CLIENT_DIR}/${USERNAME}-udp.ovpn"
echo -e "  ${CYAN}Download file tersebut ke perangkat client.${NC}"
echo ""
echo -e "  ${BYELLOW}Tip UDP${NC}: Jika jaringan tidak stabil, gunakan TCP sebagai backup."
divider
echo ""
press_any_key
menu-ovpn
