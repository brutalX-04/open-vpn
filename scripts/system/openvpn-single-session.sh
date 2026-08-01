#!/bin/bash
# Called by OpenVPN on client connect/disconnect. A common name may have only
# one active connection across the TCP and UDP daemons.

set -eu
ACTION="${1:-}"
USERNAME="${common_name:-}"
[[ "${USERNAME}" =~ ^[a-zA-Z0-9_.-]+$ ]] || exit 1
STATE_DIR=/run/vpn-openvpn-sessions
STATE_FILE="${STATE_DIR}/${USERNAME}"
SESSION_ID="${trusted_ip:-unknown}:${trusted_port:-unknown}"
mkdir -p "${STATE_DIR}"

case "${ACTION}" in
    connect)
        if ! (set -o noclobber; printf '%s\n' "${SESSION_ID}" > "${STATE_FILE}") 2>/dev/null; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] SESSION-LIMIT | openvpn | denied user=${USERNAME}" >> /var/log/vpn/session-limit.log
            exit 1
        fi
        ;;
    disconnect)
        if [[ -f "${STATE_FILE}" ]] && [[ "$(cat "${STATE_FILE}")" == "${SESSION_ID}" ]]; then
            rm -f "${STATE_FILE}"
        fi
        ;;
    *) exit 2 ;;
esac
