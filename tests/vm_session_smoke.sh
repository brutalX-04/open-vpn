#!/bin/bash
# Real SSH and OpenVPN session-guard checks. Run only as root on a test VM.
set -euo pipefail
[[ "${EUID}" -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
CLI=/usr/local/bin/vpn-cli
PYTHON=/etc/vpn/venv/bin/python
suffix=$(openssl rand -hex 4)
ovuser="codexo${suffix}"
sshuser="codxs${suffix}"
tmp="/run/vpn/session-smoke-${suffix}"
mkdir -m 700 "${tmp}"

cleanup() {
    for name in tcp udp ssh1 ssh2; do
        if [[ -s "${tmp}/${name}.pid" ]]; then
            kill "$(cat "${tmp}/${name}.pid")" 2>/dev/null || true
        fi
    done
    if [[ -n "${sshuser:-}" ]]; then
        pkill -KILL -u "${sshuser}" 2>/dev/null || true
        "${CLI}" delete --service ssh --user "${sshuser}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${ovuser:-}" ]]; then
        "${CLI}" delete --service ovpn-tcp --user "${ovuser}" >/dev/null 2>&1 || true
        "${CLI}" delete --service ovpn-udp --user "${ovuser}" >/dev/null 2>&1 || true
    fi
    if [[ "${rc:-0}" -eq 0 ]]; then rm -rf -- "${tmp}"; else echo "Diagnostic files retained in ${tmp}." >&2; fi
}
trap 'rc=$?; if [[ "${rc}" -ne 0 ]]; then echo "Session smoke failed (status ${rc}); diagnostics: ${tmp}" >&2; fi; cleanup' EXIT

sessions_json() {
    PYTHONPATH=/etc/vpn "${PYTHON}" -c 'import json; from vpnctl.guard import openvpn_sessions; print(json.dumps(openvpn_sessions()))'
}
wait_ovpn_proto() {
    local proto=$1 expected=$2 i rows
    for ((i=0; i<20; i++)); do
        rows=$(sessions_json)
        if ROWS="${rows}" USERNAME="${ovuser}" PROTO="${proto}" EXPECTED="${expected}" "${PYTHON}" -c 'import json,os,sys; rows=[r for r in json.loads(os.environ["ROWS"]) if r["username"]==os.environ["USERNAME"]]; sys.exit(0 if len(rows)==int(os.environ["EXPECTED"]) and (not os.environ["PROTO"] or all(r["proto"]==os.environ["PROTO"] for r in rows)) else 1)' 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    printf '%s\n' "${rows:-[]}" >&2
    PYTHONPATH=/etc/vpn "${PYTHON}" - <<'PY' >&2
import csv
from vpnctl.guard import _management
for proto in ("tcp", "udp"):
    try:
        text = _management(proto)
        print(f"raw status proto={proto} record_types={[line.split(',', 1)[0] for line in text.splitlines() if line]}")
        for line in text.splitlines():
            if line.startswith("CLIENT_LIST,"):
                fields = next(csv.reader([line]))
                print(f"raw status proto={proto} fields={len(fields)} selected={[(i, fields[i]) for i in (1, 5, 8, 9, 10) if i < len(fields)]}")
    except Exception as exc:
        print(f"raw status proto={proto} error={type(exc).__name__}")
PY
    return 1
}

"${CLI}" create --service ovpn-tcp --user "${ovuser}" --days 1 --max-sessions 1 >/dev/null
"${CLI}" create --service ovpn-udp --user "${ovuser}" --days 1 --max-sessions 1 >/dev/null
for proto in tcp udp; do
    sed -e 's/^remote .*/remote 127.0.0.1 1194/' -e '/^client$/a route-nopull' \
        "/etc/openvpn/clients/${ovuser}-${proto}.ovpn" >"${tmp}/${proto}.ovpn"
    chmod 600 "${tmp}/${proto}.ovpn"
done

openvpn --config "${tmp}/tcp.ovpn" --writepid "${tmp}/tcp.pid" --log "${tmp}/tcp.log" >"${tmp}/tcp-stdout.log" 2>&1 &
echo $! >"${tmp}/tcp.pid"
wait_ovpn_proto tcp 1 || { echo "OpenVPN TCP test client did not connect:" >&2; grep -E 'Initialization Sequence Completed|ERROR|Error|VERIFY|TLS Error|Options error|Exiting' "${tmp}/tcp.log" | tail -12 >&2 || true; exit 1; }
start_time=$(date --iso-8601=seconds)
openvpn --config "${tmp}/udp.ovpn" --writepid "${tmp}/udp.pid" --log "${tmp}/udp.log" >"${tmp}/udp-stdout.log" 2>&1 &
echo $! >"${tmp}/udp.pid"
wait_ovpn_proto udp 1 || { echo "OpenVPN UDP test client did not connect:" >&2; grep -E 'Initialization Sequence Completed|ERROR|Error|VERIFY|TLS Error|Options error|Exiting' "${tmp}/udp.log" | tail -12 >&2 || true; exit 1; }

guard_seen=0
for ((i=0; i<15; i++)); do
    if journalctl -u vpn-session-guard.service --since "${start_time}" --no-pager -o cat 2>/dev/null | grep -F "service=ovpn-tcp user=${ovuser} action=kill reason=over_limit" >/dev/null; then
        guard_seen=1
        break
    fi
    sleep 1
done
[[ "${guard_seen}" -eq 1 ]] || { echo "OpenVPN session guard did not kill the older TCP session." >&2; exit 1; }
kill "$(cat "${tmp}/tcp.pid")" 2>/dev/null || true
wait_ovpn_proto udp 1 || { echo "The newer UDP session did not remain connected." >&2; exit 1; }
echo "OpenVPN cross-protocol limit passed; newer UDP session remained."

ssh-keygen -q -t ed25519 -N '' -f "${tmp}/id_ed25519"
"${CLI}" create --service ssh --user "${sshuser}" --days 1 --max-sessions 1 --password-stdin < <(openssl rand -hex 18) >/dev/null
home=$(getent passwd "${sshuser}" | cut -d: -f6)
group=$(id -gn "${sshuser}")
install -d -m 700 -o "${sshuser}" -g "${group}" "${home}/.ssh"
install -m 600 -o "${sshuser}" -g "${group}" "${tmp}/id_ed25519.pub" "${home}/.ssh/authorized_keys"
ssh_opts=(-i "${tmp}/id_ed25519" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ExitOnForwardFailure=yes -vv -N -D)
ssh "${ssh_opts[@]}" 127.0.0.1:10871 "${sshuser}@127.0.0.1" >"${tmp}/ssh1.log" 2>&1 &
echo $! >"${tmp}/ssh1.pid"
for ((i=0; i<10; i++)); do grep -q 'Authenticated to 127.0.0.1' "${tmp}/ssh1.log" 2>/dev/null && break; sleep 1; done
grep -q 'Authenticated to 127.0.0.1' "${tmp}/ssh1.log" || { echo "First SSH tunnel failed to authenticate." >&2; exit 1; }
start_time=$(date --iso-8601=seconds)
ssh "${ssh_opts[@]}" 127.0.0.1:10872 "${sshuser}@127.0.0.1" >"${tmp}/ssh2.log" 2>&1 &
echo $! >"${tmp}/ssh2.pid"
for ((i=0; i<15; i++)); do
    if grep -q 'SESSION-LIMIT | service=ssh user='"${sshuser}"' action=kill reason=over_limit' < <(journalctl -u vpn-session-guard.service --since "${start_time}" --no-pager -o cat 2>/dev/null); then
        break
    fi
    sleep 1
done
journalctl -u vpn-session-guard.service --since "${start_time}" --no-pager -o cat 2>/dev/null | grep -F "SESSION-LIMIT | service=ssh user=${sshuser} action=kill reason=over_limit" >/dev/null || {
    echo "SSH session guard did not terminate the newer tunnel." >&2
    ps -eo pid=,etimes=,user=,args= | grep '[s]shd' >&2 || true
    grep -E 'Authenticated to|Connection established|Entering interactive session|Connection closed' "${tmp}/ssh1.log" "${tmp}/ssh2.log" >&2 || true
    journalctl -u vpn-session-guard.service --since "${start_time}" --no-pager -o cat 2>/dev/null | tail -12 >&2 || true
    exit 1
}
ssh_sessions() {
    TEST_USER="${sshuser}" PYTHONPATH=/etc/vpn "${PYTHON}" -c 'import os,subprocess; from vpnctl.guard import _ssh_session_username; rows=subprocess.run(["ps","-eo","args="],capture_output=True,text=True,check=True).stdout.splitlines(); print(sum(_ssh_session_username(row)==os.environ["TEST_USER"] for row in rows))'
}
for ((i=0; i<10; i++)); do [[ "$(ssh_sessions)" -eq 1 ]] && break; sleep 1; done
[[ "$(ssh_sessions)" -eq 1 ]] || { echo "SSH guard should leave exactly one server-side tunnel." >&2; exit 1; }
echo "SSH limit passed; older tunnel remained and newer no-PTY tunnel was terminated."

# Revoke the shared disposable CN, then check a fresh TLS handshake without
# restarting either OpenVPN daemon.
kill "$(cat "${tmp}/udp.pid")" 2>/dev/null || true
server_pids_before=$(systemctl show vpn-openvpn-tcp.service vpn-openvpn-udp.service --property=MainPID --value)
revoke_start_time=$(date --iso-8601=seconds)
"${CLI}" delete --service ovpn-tcp --user "${ovuser}" >/dev/null
"${CLI}" delete --service ovpn-udp --user "${ovuser}" >/dev/null
wait_ovpn_proto "" 0 || { echo "OpenVPN sessions remained after account deletion." >&2; exit 1; }
set +e
timeout 15s openvpn --config "${tmp}/tcp.ovpn" --route-nopull --log "${tmp}/revoked.log" >/dev/null 2>&1
client_status=$?
set -e
if [[ "${client_status}" -eq 0 ]] || ! journalctl -u vpn-openvpn-tcp.service --since "${revoke_start_time}" --no-pager -o cat | grep -F "VERIFY ERROR: depth=0, error=certificate revoked: CN=${ovuser}" >/dev/null; then
    echo "The OpenVPN server did not reject the revoked client certificate on a new handshake." >&2
    grep -E 'VERIFY ERROR|TLS Error|Initialization Sequence Completed' "${tmp}/revoked.log" | tail -10 >&2 || true
    exit 1
fi
server_pids_after=$(systemctl show vpn-openvpn-tcp.service vpn-openvpn-udp.service --property=MainPID --value)
[[ "${server_pids_before}" == "${server_pids_after}" ]] || { echo "OpenVPN restarted during certificate revocation." >&2; exit 1; }
echo "Fresh handshake rejected the revoked certificate without restarting OpenVPN."
