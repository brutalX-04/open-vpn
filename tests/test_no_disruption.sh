#!/bin/bash
# Static safety gate. Live PID/session preservation still requires the target VM.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if grep -REn 'shell[[:space:]]*=[[:space:]]*True|shell=True' "${ROOT}/vpnctl" "${ROOT}/api" "${ROOT}/scripts/api"; then
    echo "Unsafe shell execution found." >&2
    exit 1
fi

if grep -REn 'systemctl[[:space:]]+(restart|reload|stop)[[:space:]]+(xray|vpn-openvpn-[^[:space:]]+|ssh|dropbear|stunnel4|nginx)' \
    "${ROOT}/scripts/ssh" "${ROOT}/scripts/xray" "${ROOT}/scripts/openvpn" "${ROOT}/scripts/system/cleanup.sh" "${ROOT}/vpnctl" "${ROOT}/api"; then
    echo "Account operations must not restart or reload shared services." >&2
    exit 1
fi

if grep -REn 'client-connect|client-disconnect|vpn-tendang|vpn-session-limit' "${ROOT}/scripts" "${ROOT}/vpnctl"; then
    echo "Legacy session limit hook is still referenced." >&2
    exit 1
fi

echo "Static no-disruption checks passed. Live service/session checks require a Debian/Ubuntu VM."
