#!/bin/bash
# ============================================================
#  xray/create-vmess.sh — Buat Akun Vmess (WS + gRPC)
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

XRAY_CONFIG="/etc/xray/config.json"

clear
header "  BUAT AKUN VMESS  "
echo ""

read -rp "$(echo -e "  ${BCYAN}Username        : ${NC}")" USERNAME
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

# Cek duplikasi username di xray config
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
    if inbound.get("tag") == "vmess-ws":
        inbound.setdefault("settings", {}).setdefault("clients", []).append(
            {"id": uuid, "alterId": 0, "email": username, "comment": f"{username} {expiry}"})
with open(path, "w") as f: json.dump(config, f, indent=2); f.write("\n")
PY

systemctl restart xray &>/dev/null

# ── Generate Link ──────────────────────────────────────────
import_vmess_tls=$(echo -n "{\"v\":\"2\",\"ps\":\"${USERNAME}\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"path\":\"/vmess\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\"}" | base64 -w 0)

import_vmess_ntls=$(echo -n "{\"v\":\"2\",\"ps\":\"${USERNAME}\",\"add\":\"${DOMAIN}\",\"port\":\"80\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"path\":\"/vmess\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"tls\":\"none\"}" | base64 -w 0)

import_vmess_grpc=$(echo -n "{\"v\":\"2\",\"ps\":\"${USERNAME}\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"grpc\",\"path\":\"vmess-grpc\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\"}" | base64 -w 0)

LINK_TLS="vmess://${import_vmess_tls}"
LINK_NTLS="vmess://${import_vmess_ntls}"
LINK_GRPC="vmess://${import_vmess_grpc}"

# ── Log ────────────────────────────────────────────────────
echo "[${NOW}] CREATE | vmess | user=${USERNAME} | uuid=${UUID} | exp=${EXPIRE}" >> /var/log/vpn/xray-users.log

# ── Tampilkan Hasil ────────────────────────────────────────
clear
header "  AKUN VMESS BERHASIL DIBUAT  "
echo ""
echo -e "  ${BWHITE}Username    ${NC}: ${BGREEN}${USERNAME}${NC}"
echo -e "  ${BWHITE}UUID        ${NC}: ${CYAN}${UUID}${NC}"
echo -e "  ${BWHITE}Expired     ${NC}: ${BGREEN}$(date -d "${EXPIRE}" +"%d %B %Y")${NC}"
echo -e "  ${BWHITE}Domain      ${NC}: ${DOMAIN}"
divider
echo -e "  ${BYELLOW}Vmess WS TLS (port 443)${NC}"
echo -e "  ${CYAN}${LINK_TLS}${NC}"
echo ""
echo -e "  ${BYELLOW}Vmess WS non-TLS (port 80)${NC}"
echo -e "  ${CYAN}${LINK_NTLS}${NC}"
echo ""
echo -e "  ${BYELLOW}Vmess gRPC TLS (port 443)${NC}"
echo -e "  ${CYAN}${LINK_GRPC}${NC}"
divider
echo ""
press_any_key
menu-xray
