#!/usr/bin/env bash
# Idempotent removal of the legacy integration. Run as root on an old installation.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo 'Jalankan penghapus integrasi lama sebagai root.' >&2
    exit 1
fi

systemctl disable --now bot-vpn.service >/dev/null 2>&1 || true
if [[ -f /etc/systemd/system/bot-vpn.service ]]; then
    rm -f /etc/systemd/system/bot-vpn.service
    systemctl daemon-reload
fi

if [[ -d /etc/vpn/bot ]]; then
    # Best-effort secure deletion of the old credentials (SSD snapshots cannot be guaranteed).
    if command -v shred >/dev/null 2>&1; then
        for secret in /etc/vpn/bot/config.json /etc/vpn/bot/trial_users.json*; do
            [[ -f "${secret}" && ! -L "${secret}" ]] && shred -u -- "${secret}" || true
        done
    fi
    rm -rf -- /etc/vpn/bot
fi

echo 'Integrasi lama dibersihkan. Rotasi token Telegram dan kunci Xendit yang pernah disimpan.'
