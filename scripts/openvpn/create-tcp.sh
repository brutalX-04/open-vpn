#!/bin/bash
# ============================================================
#  openvpn/create-tcp.sh — Buat Akun OpenVPN TCP
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

OVPN_DIR="/etc/openvpn"
CLIENT_DIR="${OVPN_DIR}/clients"
CA_DIR="${OVPN_DIR}/easy-rsa"

clear
header "  BUAT AKUN OpenVPN TCP  "
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

if [[ -f "${CLIENT_DIR}/${USERNAME}-tcp.ovpn" ]]; then
    error "Username '${USERNAME}' sudah ada!"
    exit 1
fi

# ── Generate Client Certificate ────────────────────────────
info "Membuat sertifikat untuk ${USERNAME}..."
EXPIRE=$(date -d "+${DAYS} days" +"%Y-%m-%d")
IP=$(get_config "IP")
PORT_TCP=$(get_config "PORT_OVPN_TCP")
[[ -z "${PORT_TCP}" ]] && PORT_TCP="1194"

cd "${CA_DIR}" || { error "Easy-RSA dir tidak ditemukan!"; exit 1; }
EASYRSA_CERT_EXPIRE="${DAYS}" ./easyrsa --batch build-client-full "${USERNAME}" nopass &>/dev/null

mkdir -p "${CLIENT_DIR}"

# ── Generate .ovpn file ────────────────────────────────────
cat > "${CLIENT_DIR}/${USERNAME}-tcp.ovpn" <<EOF
# OpenVPN TCP Client Config
# Username  : ${USERNAME}
# Expired   : ${EXPIRE}
# Generated : ${NOW}

client
dev tun
proto tcp
remote ${IP} ${PORT_TCP}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
cipher AES-256-CBC
compress lz4-v2
key-direction 1
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
echo "[${NOW}] CREATE | ovpn-tcp | user=${USERNAME} | exp=${EXPIRE}" >> /var/log/vpn/ovpn-users.log

# ── Tampilkan Hasil ────────────────────────────────────────
clear
header "  AKUN OpenVPN TCP BERHASIL DIBUAT  "
echo ""
echo -e "  ${BWHITE}Username    ${NC}: ${BGREEN}${USERNAME}${NC}"
echo -e "  ${BWHITE}Protokol    ${NC}: ${BCYAN}TCP${NC}"
echo -e "  ${BWHITE}Server      ${NC}: ${IP}"
echo -e "  ${BWHITE}Port        ${NC}: ${PORT_TCP}"
echo -e "  ${BWHITE}Expired     ${NC}: ${BGREEN}$(date -d "${EXPIRE}" +"%d %B %Y")${NC}"
divider
echo -e "  ${BYELLOW}File config${NC}: ${CLIENT_DIR}/${USERNAME}-tcp.ovpn"
echo -e "  ${CYAN}Download file tersebut ke perangkat client.${NC}"
divider
echo ""
press_any_key
menu-ovpn
