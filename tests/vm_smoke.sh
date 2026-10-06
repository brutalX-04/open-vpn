#!/bin/bash
# Live integration smoke test. Run only as root on a disposable test VM.
set -euo pipefail
if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
fi

CLI=/usr/local/bin/vpn-cli
[[ -x "${CLI}" ]] || { echo "vpn-cli is not installed." >&2; exit 1; }
suffix="$(openssl rand -hex 4)"
xuser="codexx${suffix}"
ouser="codexo${suffix}"
suser="codexs${suffix}"
exuser="codexe${suffix}"
exouser="codexeo${suffix}"
exsuser="codexes${suffix}"
api_ssh_user="codexa${suffix}"
api_ovpn_user="codexao${suffix}"

cleanup() {
    "${CLI}" delete --service ssh --user "${suser}" >/dev/null 2>&1 || true
    "${CLI}" delete --service ovpn-tcp --user "${ouser}" >/dev/null 2>&1 || true
    "${CLI}" delete --service ovpn-udp --user "${ouser}" >/dev/null 2>&1 || true
    for service in vmess vless trojan; do
        "${CLI}" delete --service "${service}" --user "${xuser}" >/dev/null 2>&1 || true
        "${CLI}" delete --service "${service}" --user "${exuser}" >/dev/null 2>&1 || true
    done
    "${CLI}" delete --service ovpn-tcp --user "${exouser}" >/dev/null 2>&1 || true
    "${CLI}" delete --service ovpn-udp --user "${exouser}" >/dev/null 2>&1 || true
    "${CLI}" delete --service ssh --user "${exsuser}" >/dev/null 2>&1 || true
    "${CLI}" delete --service ssh --user "${api_ssh_user}" >/dev/null 2>&1 || true
    "${CLI}" delete --service ovpn-tcp --user "${api_ovpn_user}" >/dev/null 2>&1 || true
    "${CLI}" delete --service ovpn-udp --user "${api_ovpn_user}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

snapshot() {
    for unit in ssh.service xray.service vpn-openvpn-tcp.service vpn-openvpn-udp.service vpn-api.service; do
        printf '%s:%s:%s\n' "${unit}" \
            "$(systemctl show "${unit}" --property=MainPID --value)" \
            "$(systemctl show "${unit}" --property=ActiveEnterTimestamp --value)"
    done
}

before="$(snapshot)"
for service in vmess vless trojan; do
    "${CLI}" create --service "${service}" --user "${xuser}" --days 1 >/dev/null
    for _ in {1..10}; do
        "${CLI}" renew --service "${service}" --user "${xuser}" --days 1 >/dev/null
    done
    "${CLI}" delete --service "${service}" --user "${xuser}" >/dev/null
done

"${CLI}" create --service ovpn-tcp --user "${ouser}" --days 1 >/dev/null
"${CLI}" create --service ovpn-udp --user "${ouser}" --days 1 >/dev/null
test -f "/etc/openvpn/clients/${ouser}-tcp.ovpn"
test -f "/etc/openvpn/clients/${ouser}-udp.ovpn"
"${CLI}" delete --service ovpn-tcp --user "${ouser}" >/dev/null
test ! -f "/etc/openvpn/clients/${ouser}-tcp.ovpn"
test -f "/etc/openvpn/clients/${ouser}-udp.ovpn"
"${CLI}" delete --service ovpn-udp --user "${ouser}" >/dev/null
test ! -f "/etc/openvpn/clients/${ouser}-udp.ovpn"
openssl crl -in /etc/openvpn/crl.pem -noout -nextupdate >/dev/null

"${CLI}" create --service ssh --user "${suser}" --days 1 >/dev/null
for _ in {1..10}; do
    "${CLI}" renew --service ssh --user "${suser}" --days 1 >/dev/null
done
"${CLI}" delete --service ssh --user "${suser}" >/dev/null
if getent passwd "${suser}" >/dev/null; then
    echo "SSH test account remains after deletion." >&2
    exit 1
fi

# Force-expiry for disposable accounts so cleanup can be verified without
# waiting on wall-clock time. This touches only the uniquely named test rows.
"${CLI}" create --service vmess --user "${exuser}" --days 1 >/dev/null
"${CLI}" create --service ssh --user "${exsuser}" --days 1 >/dev/null
"${CLI}" create --service ovpn-tcp --user "${exouser}" --days 1 >/dev/null
"${CLI}" create --service ovpn-udp --user "${exouser}" --days 1 >/dev/null
VPN_SMOKE_USERS="${exuser},${exsuser},${exouser}" /etc/vpn/venv/bin/python - <<'PY'
import os
import sqlite3

users = os.environ["VPN_SMOKE_USERS"].split(",")
with sqlite3.connect("/var/lib/vpn/accounts.db") as db:
    db.executemany("UPDATE accounts SET expires_at=1 WHERE username=?", ((user,) for user in users))
PY
"${CLI}" cleanup >/dev/null
if getent passwd "${exsuser}" >/dev/null; then
    echo "Expired SSH test account remains." >&2
    exit 1
fi
test ! -e "/etc/openvpn/clients/${exouser}-tcp.ovpn"
test ! -e "/etc/openvpn/clients/${exouser}-udp.ovpn"
VPN_SMOKE_USERS="${exuser},${exsuser},${exouser}" /etc/vpn/venv/bin/python - <<'PY'
import json
import os
import sqlite3

users = os.environ["VPN_SMOKE_USERS"].split(",")
with sqlite3.connect("/var/lib/vpn/accounts.db") as db:
    for user in users:
        assert db.execute("SELECT 1 FROM accounts WHERE username=?", (user,)).fetchone() is None
with open("/etc/xray/config.json", encoding="utf-8") as stream:
    config = json.load(stream)
assert not any(client.get("email") in users for inbound in config.get("inbounds", [])
               for client in inbound.get("settings", {}).get("clients", []))
PY
openssl crl -in /etc/openvpn/crl.pem -noout -nextupdate >/dev/null

after="$(snapshot)"
if [[ "${before}" != "${after}" ]]; then
    printf 'Shared service state changed during account operations.\nBefore:\n%s\nAfter:\n%s\n' \
        "${before}" "${after}" >&2
    exit 1
fi

VPN_API_ENV=/etc/vpn/api.env VPN_API_SSH_USER="${api_ssh_user}" VPN_API_OVPN_USER="${api_ovpn_user}" \
    VPN_API_TEST_ID="vm-smoke-${suffix}" /etc/vpn/venv/bin/python - <<'PY'
import json
import os
import urllib.error
import urllib.request

settings = {}
with open(os.environ["VPN_API_ENV"], encoding="utf-8") as stream:
    for line in stream:
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.rstrip().split("=", 1)
            settings[key] = value
api_key = settings["API_KEY"]
base = "http://127.0.0.1:8088"

def request(method, path, body=None, idempotency_key=None, key=api_key):
    headers = {"X-API-Key": key}
    payload = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        payload = json.dumps(body).encode()
    if idempotency_key:
        headers["Idempotency-Key"] = idempotency_key
    req = urllib.request.Request(base + path, data=payload, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise RuntimeError(f"{method} {path} returned HTTP {error.code}: {detail}") from error

with urllib.request.urlopen(base + "/v1/health", timeout=5) as response:
    assert response.status == 200 and json.load(response)["data"]["ok"]
code, result = request("GET", "/v1/services")
assert code == 200 and "data" in result
xray = [service for service in result["data"]["services"] if service["id"] == "vmess"]
assert xray and not xray[0]["available"] and xray[0]["reason"]
code, result = request("GET", "/v1/status")
assert code == 200 and "online" in result["data"]

ssh_user = os.environ["VPN_API_SSH_USER"]
idem = os.environ["VPN_API_TEST_ID"]
payload = {"service": "ssh", "username": ssh_user, "days": 1}
first_code, first = request("POST", "/v1/accounts", payload, idem)
second_code, second = request("POST", "/v1/accounts", payload, idem)
assert first_code == second_code == 201 and first == second
request("DELETE", f"/v1/accounts/ssh/{ssh_user}")

ovpn_user = os.environ["VPN_API_OVPN_USER"]
for proto in ("tcp", "udp"):
    code, _ = request("POST", "/v1/accounts", {"service": f"ovpn-{proto}", "username": ovpn_user, "days": 1})
    assert code == 201
for proto in ("tcp", "udp"):
    code, _ = request("DELETE", f"/v1/accounts/ovpn-{proto}/{ovpn_user}")
    assert code == 200

try:
    urllib.request.urlopen(base + "/v1/status", timeout=5)
except urllib.error.HTTPError as error:
    assert error.code == 401
else:
    raise AssertionError("API accepted a request without an API key")
PY

echo "Live smoke tests passed; service PIDs and ActiveEnterTimestamps were unchanged."
