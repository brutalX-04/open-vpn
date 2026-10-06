#!/bin/bash
# Account A stays connected while disposable account B is mutated in parallel.
# Run only as root on a disposable test VM with the OpenVPN / Xray stack installed.
set -euo pipefail
[[ "${EUID}" -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
CLI=/usr/local/bin/vpn-cli
PYTHON=/etc/vpn/venv/bin/python
suffix=$(openssl rand -hex 4)
tmp="/run/vpn/active-smoke-${suffix}"
mkdir -m 700 "${tmp}"

a_ssh="codxas${suffix}"
a_xray="codxav${suffix}"
a_ovpn="codxao${suffix}"
c_ssh="codxcs${suffix}"
c_xray="codxcv${suffix}"
c_ovpn="codxco${suffix}"
a_ssh_pid= a_vmess_pid= a_tcp_pid= a_udp_pid=
c_ssh_pid= c_vmess_pid= c_tcp_pid= c_udp_pid=
http_pid=

services=(ssh vmess vless trojan ovpn-tcp ovpn-udp)
user_key() {
    case "$1" in
        ssh) echo s;; vmess) echo m;; vless) echo l;; trojan) echo t;; ovpn-*) echo o;;
    esac
}
user_for() { printf 'codexb%s%s%02d' "$(user_key "$1")" "${suffix}" "$2"; }
create_ssh() { openssl rand -hex 18 | "${CLI}" create --service ssh --user "$1" --days 1 --password-stdin >/dev/null; }
create_one() {
    local service=$1 username=$2
    if [[ "${service}" == ssh ]]; then create_ssh "${username}";
    else "${CLI}" create --service "${service}" --user "${username}" --days 1 >/dev/null; fi
}
delete_one() { "${CLI}" delete --service "$1" --user "$2" >/dev/null; }

cleanup() {
    for name in a_ssh_pid a_vmess_pid a_tcp_pid a_udp_pid c_ssh_pid c_vmess_pid c_tcp_pid c_udp_pid; do
        pid=${!name:-}
        [[ -z "${pid}" ]] || kill "${pid}" 2>/dev/null || true
    done
    for user in "${a_ssh}" "${c_ssh}"; do
        pkill -KILL -u "${user}" 2>/dev/null || true
        "${CLI}" delete --service ssh --user "${user}" >/dev/null 2>&1 || true
    done
    [[ -z "${http_pid}" ]] || kill "${http_pid}" 2>/dev/null || true
    for user in "${a_xray}" "${c_xray}"; do
        "${CLI}" delete --service vmess --user "${user}" >/dev/null 2>&1 || true
    done
    for user in "${a_ovpn}" "${c_ovpn}"; do
        "${CLI}" delete --service ovpn-tcp --user "${user}" >/dev/null 2>&1 || true
        "${CLI}" delete --service ovpn-udp --user "${user}" >/dev/null 2>&1 || true
    done
    for service in "${services[@]}"; do
        while IFS= read -r user; do
            [[ -z "${user}" ]] || delete_one "${service}" "${user}" 2>/dev/null || true
        done <"${tmp}/users-${service}"
    done
    for service in "${services[@]}"; do
        user="${tmp}/expire-$(user_key "${service}")"
        [[ ! -s "${user}" ]] || delete_one "${service}" "$(cat "${user}")" 2>/dev/null || true
    done
    if [[ "${rc:-0}" -eq 0 ]]; then rm -rf -- "${tmp}"; else echo "Diagnostic files retained in ${tmp}." >&2; fi
}
for service in "${services[@]}"; do : >"${tmp}/users-${service}"; done
trap 'rc=$?; if [[ "${rc}" -ne 0 ]]; then echo "Active no-disruption test failed (status ${rc}); diagnostics: ${tmp}" >&2; fi; cleanup' EXIT

snapshot() {
    for unit in ssh.service xray.service vpn-openvpn-tcp.service vpn-openvpn-udp.service vpn-api.service vpn-session-guard.service; do
        printf '%s:%s:%s\n' "${unit}" "$(systemctl show "${unit}" --property=MainPID --value)" \
            "$(systemctl show "${unit}" --property=ActiveEnterTimestamp --value)"
    done
}

install_ssh_key() {
    local user=$1
    local home group
    home=$(getent passwd "${user}" | cut -d: -f6)
    group=$(id -gn "${user}")
    install -d -m 700 -o "${user}" -g "${group}" "${home}/.ssh"
    install -m 600 -o "${user}" -g "${group}" "${tmp}/id_ed25519.pub" "${home}/.ssh/authorized_keys"
}
start_ssh() {
    local user=$1 port=$2 logfile=$3
    ssh -i "${tmp}/id_ed25519" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ExitOnForwardFailure=yes -v -N -D "127.0.0.1:${port}" \
        "${user}@127.0.0.1" >"${logfile}" 2>&1 &
    echo $!
}
make_local_ovpn() {
    local user=$1 proto=$2 out=$3
    sed -e 's/^remote .*/remote 127.0.0.1 1194/' -e '/^client$/a route-nopull' \
        "/etc/openvpn/clients/${user}-${proto}.ovpn" >"${out}"
    chmod 600 "${out}"
}
start_ovpn() {
    local user=$1 proto=$2
    make_local_ovpn "${user}" "${proto}" "${tmp}/${user}-${proto}.ovpn"
    openvpn --config "${tmp}/${user}-${proto}.ovpn" --writepid "${tmp}/${user}-${proto}.pid" \
        --log "${tmp}/${user}-${proto}.log" >"${tmp}/${user}-${proto}-stdout.log" 2>&1 &
    echo $! >"${tmp}/${user}-${proto}.pid"
}
ovpn_rows() {
    TEST_USER="$1" PYTHONPATH=/etc/vpn "${PYTHON}" -c \
        'import json,os; from vpnctl.guard import openvpn_sessions; print(json.dumps([r for r in openvpn_sessions() if r["username"]==os.environ["TEST_USER"]]))'
}
wait_ovpn_count() {
    local user=$1 expected=$2 count i rows
    for ((i=0; i<20; i++)); do
        rows=$(ovpn_rows "${user}")
        count=$(ROWS="${rows}" "${PYTHON}" -c 'import json,os; print(len(json.loads(os.environ["ROWS"])))')
        [[ "${count}" -eq "${expected}" ]] && return 0
        sleep 1
    done
    echo "OpenVPN session count for disposable account ${user} was ${count}, expected ${expected}." >&2
    return 1
}
make_xray_client() {
    local user=$1 port=$2
    local result uuid
    result=$("${CLI}" create --service vmess --user "${user}" --days 1)
    uuid=$(printf '%s' "${result}" | jq -r '.data.meta.uuid')
    XRAY_TEST_UUID="${uuid}" XRAY_TEST_PORT="${port}" python3 - "${tmp}/${user}-xray.json" <<'PY'
import json
import os
import sys
config = {
    "log": {"loglevel": "error"},
    "inbounds": [{"listen": "127.0.0.1", "port": int(os.environ["XRAY_TEST_PORT"]),
                  "protocol": "socks", "settings": {"auth": "noauth", "udp": False}}],
    "outbounds": [{"protocol": "vmess", "settings": {"vnext": [{"address": "127.0.0.1", "port": 10001,
                  "users": [{"id": os.environ["XRAY_TEST_UUID"], "alterId": 0, "security": "auto"}]}]},
                  "streamSettings": {"network": "ws", "wsSettings": {"path": "/vmess"}}}],
}
with open(sys.argv[1], "w", encoding="utf-8") as stream: json.dump(config, stream)
PY
}
start_xray_client() {
    local user=$1 port=$2
    /usr/local/bin/xray run -config "${tmp}/${user}-xray.json" >"${tmp}/${user}-xray.log" 2>&1 &
    echo $!
}
check_ssh_session() {
    TEST_USER="$1" PYTHONPATH=/etc/vpn "${PYTHON}" - <<'PY'
import os
import re
import subprocess
from vpnctl.guard import _ssh_session_username
name = os.environ["TEST_USER"]
rows = subprocess.run(["ps", "-eo", "args="], capture_output=True, text=True, check=True).stdout.splitlines()
matches = [args for args in rows if _ssh_session_username(args) == name]
assert len(matches) == 1, f"expected one no-PTY server process for test user, found {len(matches)}"
PY
}
check_xray_client() {
    local port=$1
    code=$(curl --silent --show-error --max-time 3 --socks5-hostname "127.0.0.1:${port}" \
        -o /dev/null -w '%{http_code}' http://127.0.0.1:18081/)
    [[ "${code}" == 200 ]]
}
check_active_a() {
    kill -0 "${a_ssh_pid}" 2>/dev/null
    check_ssh_session "${a_ssh}"
    wait_ovpn_count "${a_ovpn}" 2
    check_xray_client 18089
}

# Two local-only HTTP targets demonstrate that both independent Xray clients
# can keep using their accounts while other accounts change.
python3 -m http.server 18081 --bind 127.0.0.1 >"${tmp}/http.log" 2>&1 &
http_pid=$!
ssh-keygen -q -t ed25519 -N '' -f "${tmp}/id_ed25519"
echo "Starting account A SSH, VMess, TCP and UDP clients."
create_ssh "${a_ssh}"
install_ssh_key "${a_ssh}"
a_ssh_pid=$(start_ssh "${a_ssh}" 18091 "${tmp}/a-ssh.log")
for ((i=0; i<10; i++)); do grep -q 'Authenticated to 127.0.0.1' "${tmp}/a-ssh.log" 2>/dev/null && break; sleep 1; done
grep -q 'Authenticated to 127.0.0.1' "${tmp}/a-ssh.log"

make_xray_client "${a_xray}" 18089
a_vmess_pid=$(start_xray_client "${a_xray}" 18089)
"${CLI}" create --service ovpn-tcp --user "${a_ovpn}" --days 1 --max-sessions 2 >/dev/null
"${CLI}" create --service ovpn-udp --user "${a_ovpn}" --days 1 --max-sessions 2 >/dev/null
start_ovpn "${a_ovpn}" tcp
start_ovpn "${a_ovpn}" udp
check_active_a

baseline=$(snapshot)
echo "Account A tunnels active; starting 20 create / 10 renew / 20 delete per service for account B."

# Twenty concurrent waves, six service types in each wave. TCP and UDP share
# one disposable CN per index, matching production behavior.
for ((index=1; index<=20; index++)); do
    pids=()
    for service in "${services[@]}"; do
        username=$(user_for "${service}" "${index}")
        printf '%s\n' "${username}" >>"${tmp}/users-${service}"
        create_one "${service}" "${username}" & pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "${pid}" || { echo "Parallel create wave failed." >&2; exit 1; }; done
done
check_active_a

for service in ssh vmess vless trojan; do
    for ((index=1; index<=10; index++)); do
        "${CLI}" renew --service "${service}" --user "$(user_for "${service}" "${index}")" --days 1 >/dev/null
    done
done
for service in ovpn-tcp ovpn-udp; do
    if "${CLI}" renew --service "${service}" --user "$(user_for "${service}" 1)" --days 1 >"${tmp}/ovpn-renew.log" 2>&1; then
        echo "OpenVPN renewal unexpectedly succeeded." >&2
        exit 1
    fi
done
check_active_a

for ((index=1; index<=20; index++)); do
    pids=()
    for service in "${services[@]}"; do
        delete_one "${service}" "$(user_for "${service}" "${index}")" & pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "${pid}" || { echo "Parallel delete wave failed." >&2; exit 1; }; done
done
check_active_a

# Expire one account per protocol by changing only the disposable registry rows.
expire_ssh="codexes${suffix}"
expire_vmess="codexem${suffix}"
expire_vless="codexel${suffix}"
expire_trojan="codexet${suffix}"
expire_ovpn="codexeo${suffix}"
create_ssh "${expire_ssh}"
"${CLI}" create --service vmess --user "${expire_vmess}" --days 1 >/dev/null
"${CLI}" create --service vless --user "${expire_vless}" --days 1 >/dev/null
"${CLI}" create --service trojan --user "${expire_trojan}" --days 1 >/dev/null
"${CLI}" create --service ovpn-tcp --user "${expire_ovpn}" --days 1 >/dev/null
"${CLI}" create --service ovpn-udp --user "${expire_ovpn}" --days 1 >/dev/null
EXPIRE_USERS="${expire_ssh},${expire_vmess},${expire_vless},${expire_trojan},${expire_ovpn}" "${PYTHON}" - <<'PY'
import os
import sqlite3
users = os.environ["EXPIRE_USERS"].split(",")
with sqlite3.connect("/var/lib/vpn/accounts.db") as db:
    db.executemany("UPDATE accounts SET expires_at=1 WHERE username=?", ((user,) for user in users))
PY
cleanup_start=$(date +%s)
"${CLI}" cleanup >/dev/null
(( $(date +%s) - cleanup_start <= 70 ))
EXPIRE_USERS="${expire_ssh},${expire_vmess},${expire_vless},${expire_trojan},${expire_ovpn}" "${PYTHON}" - <<'PY'
import os
import sqlite3
users = os.environ["EXPIRE_USERS"].split(",")
with sqlite3.connect("/var/lib/vpn/accounts.db") as db:
    assert db.execute("SELECT COUNT(*) FROM accounts WHERE username IN (" + ",".join("?" for _ in users) + ")", users).fetchone()[0] == 0
PY
check_active_a
[[ "${baseline}" == "$(snapshot)" ]] || { echo "A shared service restarted or changed MainPID/timestamp." >&2; exit 1; }
"${CLI}" doctor | jq -e '.data.ok == true' >/dev/null
openssl crl -in /etc/openvpn/crl.pem -noout -nextupdate >/dev/null
echo "Account A survived parallel create/renew/delete/expiry on all service types; PIDs and start times stayed unchanged."

# Create a second active account C, then remove only A and verify C survives.
create_ssh "${c_ssh}"
install_ssh_key "${c_ssh}"
c_ssh_pid=$(start_ssh "${c_ssh}" 18092 "${tmp}/c-ssh.log")
for ((i=0; i<10; i++)); do grep -q 'Authenticated to 127.0.0.1' "${tmp}/c-ssh.log" 2>/dev/null && break; sleep 1; done
grep -q 'Authenticated to 127.0.0.1' "${tmp}/c-ssh.log"
make_xray_client "${c_xray}" 18090
c_vmess_pid=$(start_xray_client "${c_xray}" 18090)
"${CLI}" create --service ovpn-tcp --user "${c_ovpn}" --days 1 --max-sessions 2 >/dev/null
"${CLI}" create --service ovpn-udp --user "${c_ovpn}" --days 1 --max-sessions 2 >/dev/null
start_ovpn "${c_ovpn}" tcp
start_ovpn "${c_ovpn}" udp
check_ssh_session "${c_ssh}"
wait_ovpn_count "${c_ovpn}" 2
check_xray_client 18090

delete_one vmess "${a_xray}"
if check_xray_client 18089 2>/dev/null; then echo "Deleted Xray account A still accepted traffic." >&2; exit 1; fi
delete_one ssh "${a_ssh}"
for ((i=0; i<10; i++)); do kill -0 "${a_ssh_pid}" 2>/dev/null || break; sleep 1; done
kill -0 "${a_ssh_pid}" 2>/dev/null && { echo "Deleted SSH account A stayed connected." >&2; exit 1; }
delete_one ovpn-tcp "${a_ovpn}"
delete_one ovpn-udp "${a_ovpn}"
wait_ovpn_count "${a_ovpn}" 0
check_ssh_session "${c_ssh}"
wait_ovpn_count "${c_ovpn}" 2
check_xray_client 18090
echo "Deleting A ended only A's SSH, Xray and OpenVPN sessions; account C remained connected."
