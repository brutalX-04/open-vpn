#!/bin/bash
# Remove expired SSH, Xray, and OpenVPN accounts. Invoked every minute by
# vpn-expiry-cleanup.timer.

set -u

NOW=$(date '+%Y-%m-%d %H:%M:%S')
TODAY=$(date '+%Y-%m-%d')
TODAY_EPOCH=$(date -d "${TODAY}" +%s)
LOG_DIR=/var/log/vpn
XRAY_CONFIG=/etc/xray/config.json
OVPN_DIR=/etc/openvpn
CA_DIR=${OVPN_DIR}/easy-rsa
mkdir -p "${LOG_DIR}"

DELETED_SSH=0
DELETED_XRAY=0
DELETED_OVPN=0

cleanup_ssh() {
    local username uid expire_days expire_epoch
    while IFS=: read -r username _ _ _ _ _ _ expire_days _; do
        uid=$(awk -F: -v user="${username}" '$1 == user { print $3; exit }' /etc/passwd)
        [[ -z "${uid}" || "${uid}" -lt 1000 || "${username}" == "nobody" || -z "${expire_days}" ]] && continue
        expire_epoch=$((expire_days * 86400))
        if [[ "${expire_epoch}" -le "${TODAY_EPOCH}" ]]; then
            pkill -u "${username}" >/dev/null 2>&1 || true
            userdel --force "${username}" >/dev/null 2>&1 || true
            echo "[${NOW}] AUTO-DELETE | ssh | user=${username}" >> "${LOG_DIR}/cleanup.log"
            DELETED_SSH=$((DELETED_SSH + 1))
        fi
    done < /etc/shadow
}

cleanup_xray() {
    [[ -f "${XRAY_CONFIG}" ]] || return 0
    python3 - "${XRAY_CONFIG}" "${TODAY}" <<'PY'
import json
import sys
from datetime import datetime

path, today = sys.argv[1], datetime.strptime(sys.argv[2], "%Y-%m-%d").date()
with open(path, encoding="utf-8") as handle:
    config = json.load(handle)

removed = 0
for inbound in config.get("inbounds", []):
    settings = inbound.get("settings", {})
    clients = settings.get("clients", [])
    kept = []
    for client in clients:
        comment = client.get("comment", "")
        try:
            expiry = datetime.strptime(comment.rsplit(" ", 1)[1], "%Y-%m-%d").date()
        except (IndexError, ValueError):
            expiry = None
        if expiry is not None and expiry <= today:
            removed += 1
        else:
            kept.append(client)
    settings["clients"] = kept

if removed:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")
print(removed)
PY
}

cleanup_openvpn() {
    [[ -d "${OVPN_DIR}/clients" ]] || return 0
    declare -A expired_users=()
    local profile expiry username
    while IFS= read -r profile; do
        expiry=$(awk -F': *' '/^# Expired/{print $2; exit}' "${profile}")
        [[ -z "${expiry}" ]] && continue
        if [[ $(date -d "${expiry}" +%s 2>/dev/null || echo 0) -le "${TODAY_EPOCH}" ]]; then
            username=$(basename "${profile}" | sed -E 's/-(tcp|udp)\.ovpn$//')
            expired_users["${username}"]=1
        fi
    done < <(find "${OVPN_DIR}/clients" -maxdepth 1 -type f -name '*.ovpn' -print)

    for username in "${!expired_users[@]}"; do
        if [[ -f "${CA_DIR}/pki/issued/${username}.crt" ]]; then
            (cd "${CA_DIR}" && ./easyrsa --batch revoke "${username}") >/dev/null 2>&1 || true
        fi
        rm -f "${OVPN_DIR}/clients/${username}-tcp.ovpn" "${OVPN_DIR}/clients/${username}-udp.ovpn"
        echo "[${NOW}] AUTO-DELETE | openvpn | user=${username}" >> "${LOG_DIR}/cleanup.log"
        DELETED_OVPN=$((DELETED_OVPN + 1))
    done

    if [[ "${DELETED_OVPN}" -gt 0 ]]; then
        (cd "${CA_DIR}" && ./easyrsa gen-crl && cp pki/crl.pem "${OVPN_DIR}/crl.pem") >/dev/null 2>&1 || true
        systemctl restart vpn-openvpn-tcp vpn-openvpn-udp >/dev/null 2>&1 || true
    fi
}

cleanup_ssh
DELETED_XRAY=$(cleanup_xray 2>/dev/null || echo 0)
cleanup_openvpn

if [[ "${DELETED_XRAY}" -gt 0 ]]; then
    systemctl restart xray >/dev/null 2>&1 || true
fi

echo "[${NOW}] CLEANUP | ssh=${DELETED_SSH} xray=${DELETED_XRAY} openvpn=${DELETED_OVPN}" >> "${LOG_DIR}/cleanup.log"
[[ "${1:-}" == "--verbose" ]] && echo "Cleanup selesai: SSH=${DELETED_SSH}, Xray=${DELETED_XRAY}, OpenVPN=${DELETED_OVPN}"
