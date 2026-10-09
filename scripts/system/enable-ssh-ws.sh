#!/bin/bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
fi

BRIDGE_SOURCE="$(dirname "${BASH_SOURCE[0]}")/ssh-ws-bridge.py"
if [[ ! -r "${BRIDGE_SOURCE}" ]]; then
    echo "SSH WebSocket bridge source not found beside this script: ${BRIDGE_SOURCE}" >&2
    exit 1
fi
BRIDGE=/etc/vpn/scripts/system/ssh-ws-bridge.py
install -D -o root -g root -m 0755 "${BRIDGE_SOURCE}" "${BRIDGE}"

cat >/etc/systemd/system/vpn-ssh-ws.service <<'EOF'
[Unit]
Description=SSH over WebSocket bridge
After=network.target ssh.service
Wants=ssh.service

[Service]
Type=simple
User=www-data
Group=www-data
ExecStart=/usr/bin/python3 /etc/vpn/scripts/system/ssh-ws-bridge.py --listen 127.0.0.1 --port 2222 --target 127.0.0.1 --target-port 22
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vpn-ssh-ws.service
