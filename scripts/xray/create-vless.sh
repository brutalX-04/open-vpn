#!/bin/bash
# ============================================================
#  xray/create-vless.sh — Buat Akun Vless (WS + gRPC)
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

XRAY_CONFIG="/etc/xray/config.json"

clear
header "  BUAT AKUN VLESS  "
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

if grep -q "\"email\": \"${USERNAME}\"" "${XRAY_CONFIG}" 2>/dev/null; then
    error "Username '${USERNAME}' sudah ada di Xray!"
    exit 1
fi

# ── Generate UUID ──────────────────────────────────────────
UUID=$(cat /proc/sys/kernel/random/uuid)
EXPIRE=$(date -d "+${DAYS} days" +"%Y-%m-%d")
DOMAIN=$(get_config "DOMAIN")

# ── Tulis ke config.json ───────────────────────────────────
python3 - "${XRAY_CONFIG}" "${UUID}" "${USERNAME}" "${EXPIRE}" <<'PY'
import json, sys
path, uuid, username, expiry = sys.argv[1:]
with open(path) as f: config = json.load(f)
for inbound in config.get("inbounds", []):
    if inbound.get("tag") == "vless-ws":
        inbound.setdefault("settings", {}).setdefault("clients", []).append(
            {"id": uuid, "flow": "", "email": username, "comment": f"{username} {expiry}"})
with open(path, "w") as f: json.dump(config, f, indent=2); f.write("\n")
PY

systemctl restart xray &>/dev/null

# ── Generate Link ──────────────────────────────────────────
LINK_TLS="vless://${UUID}@${DOMAIN}:443?path=%2Fvless&security=tls&host=${DOMAIN}&type=ws&sni=${DOMAIN}#${USERNAME}"
LINK_NTLS="vless://${UUID}@${DOMAIN}:80?path=%2Fvless&security=none&host=${DOMAIN}&type=ws#${USERNAME}"
LINK_GRPC="vless://${UUID}@${DOMAIN}:443?mode=gun&security=tls&type=grpc&serviceName=vless-grpc&sni=${DOMAIN}#${USERNAME}"

# ── Log ────────────────────────────────────────────────────
echo "[${NOW}] CREATE | vless | user=${USERNAME} | uuid=${UUID} | exp=${EXPIRE}" >> /var/log/vpn/xray-users.log

# ── Tampilkan Hasil ────────────────────────────────────────
clear
header "  AKUN VLESS BERHASIL DIBUAT  "
echo ""
echo -e "  ${BWHITE}Username    ${NC}: ${BGREEN}${USERNAME}${NC}"
echo -e "  ${BWHITE}UUID        ${NC}: ${CYAN}${UUID}${NC}"
echo -e "  ${BWHITE}Expired     ${NC}: ${BGREEN}$(date -d "${EXPIRE}" +"%d %B %Y")${NC}"
echo -e "  ${BWHITE}Domain      ${NC}: ${DOMAIN}"
divider
echo -e "  ${BYELLOW}Vless WS TLS (port 443)${NC}"
echo -e "  ${CYAN}${LINK_TLS}${NC}"
echo ""
echo -e "  ${BYELLOW}Vless WS non-TLS (port 80)${NC}"
echo -e "  ${CYAN}${LINK_NTLS}${NC}"
echo ""
echo -e "  ${BYELLOW}Vless gRPC TLS (port 443)${NC}"
echo -e "  ${CYAN}${LINK_GRPC}${NC}"
divider
echo ""
press_any_key
menu-xray
