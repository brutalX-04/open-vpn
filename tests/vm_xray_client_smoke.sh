#!/bin/bash
# Real VMess-over-WebSocket client loopback test. Run only as root on test VM.
set -euo pipefail
[[ "${EUID}" -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
CLI=/usr/local/bin/vpn-cli
suffix=$(openssl rand -hex 4)
user="codexv${suffix}"
tmp="/run/vpn/xray-client-${suffix}"
mkdir -m 700 "${tmp}"
client_pid=
http_pid=
cleanup() {
    [[ -z "${client_pid}" ]] || kill "${client_pid}" 2>/dev/null || true
    [[ -z "${http_pid}" ]] || kill "${http_pid}" 2>/dev/null || true
    "${CLI}" delete --service vmess --user "${user}" >/dev/null 2>&1 || true
    rm -rf -- "${tmp}"
}
trap cleanup EXIT

result=$("${CLI}" create --service vmess --user "${user}" --days 1)
uuid=$(printf '%s' "${result}" | jq -r '.data.meta.uuid')
[[ "${uuid}" =~ ^[0-9a-fA-F-]{36}$ ]]

python3 -m http.server 18081 --bind 127.0.0.1 >"${tmp}/http.log" 2>&1 &
http_pid=$!
XRAY_TEST_UUID="${uuid}" python3 - "${tmp}/client.json" <<'PY'
import json
import os
import sys

config = {
    "log": {"loglevel": "error"},
    "inbounds": [{
        "listen": "127.0.0.1", "port": 18089, "protocol": "socks",
        "settings": {"auth": "noauth", "udp": False},
    }],
    "outbounds": [{
        "protocol": "vmess",
        "settings": {"vnext": [{
            "address": "127.0.0.1", "port": 10001,
            "users": [{"id": os.environ["XRAY_TEST_UUID"], "alterId": 0, "security": "auto"}],
        }]},
        "streamSettings": {"network": "ws", "wsSettings": {"path": "/vmess"}},
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(config, stream)
PY
/usr/local/bin/xray run -config "${tmp}/client.json" >"${tmp}/xray.log" 2>&1 &
client_pid=$!
for ((i=0; i<10; i++)); do
    if curl --silent --show-error --max-time 2 --socks5-hostname 127.0.0.1:18089 \
        -o /dev/null -w '%{http_code}' http://127.0.0.1:18081/ >"${tmp}/http-status" 2>/dev/null &&
        [[ "$(cat "${tmp}/http-status")" == "200" ]]; then
        echo "VMess WebSocket client passed against the local Xray inbound."
        exit 0
    fi
    kill -0 "${client_pid}" 2>/dev/null || { tail -10 "${tmp}/xray.log" >&2; exit 1; }
    sleep 1
done
echo "VMess WebSocket loopback request did not return HTTP 200." >&2
tail -10 "${tmp}/xray.log" >&2
exit 1
