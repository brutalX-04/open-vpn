"""Local diagnostics used by vpn-cli doctor."""
import json
import os
import socket
import subprocess
import time
from datetime import datetime, timezone

from .registry import Registry


def _command(*argv):
    result = subprocess.run(list(argv), text=True, capture_output=True)
    return result.returncode == 0, result.stdout.strip() or result.stderr.strip()


def doctor(registry=None, *, now=None):
    registry = registry or Registry()
    checks = []
    units = ("ssh", "xray", "vpn-openvpn-tcp", "vpn-openvpn-udp", "vpn-api", "vpn-session-guard")
    for unit in units:
        ok, detail = _command("systemctl", "is-active", unit)
        checks.append({"name": f"unit:{unit}", "ok": ok and detail == "active", "detail": detail or "inactive"})
    crl = "/etc/openvpn/crl.pem"
    if os.path.exists(crl):
        ok, detail = _command("openssl", "crl", "-in", crl, "-noout", "-nextupdate")
        remaining = None
        try:
            value = detail.split("=", 1)[1].strip()
            next_update = datetime.strptime(value, "%b %d %H:%M:%S %Y GMT").replace(tzinfo=timezone.utc)
            current = now or datetime.now(timezone.utc)
            if current.tzinfo is None:
                current = current.replace(tzinfo=timezone.utc)
            remaining = int((next_update - current.astimezone(timezone.utc)).total_seconds() / 86400)
        except (IndexError, ValueError): pass
        checks.append({"name": "openvpn-crl", "ok": ok and (remaining is None or remaining >= 30),
                       "detail": detail if remaining is None else f"{detail}; {remaining} days remain"})
    else:
        checks.append({"name": "openvpn-crl", "ok": False, "detail": "CRL file is missing"})
    server_cert = "/etc/openvpn/server/server.crt"
    if os.path.exists(server_cert):
        ok, detail = _command("openssl", "x509", "-in", server_cert, "-noout", "-enddate")
        remaining = None
        try:
            value = detail.split("=", 1)[1].strip()
            expiry = datetime.strptime(value, "%b %d %H:%M:%S %Y GMT").replace(tzinfo=timezone.utc)
            remaining = int((expiry - datetime.now(timezone.utc)).total_seconds() / 86400)
        except (IndexError, ValueError): pass
        checks.append({"name": "openvpn-server-cert", "ok": ok and (remaining is None or remaining >= 90),
                       "detail": detail if remaining is None else f"{detail}; {remaining} days remain"})
    xray_path = "/etc/xray/config.json"
    try:
        with open(xray_path, encoding="utf-8") as stream: config = json.load(stream)
        checks.append({"name": "xray-config", "ok": True, "detail": f"{len(config.get('inbounds', []))} inbounds"})
    except (OSError, ValueError) as exc:
        checks.append({"name": "xray-config", "ok": False, "detail": str(exc)})
    if os.path.exists("/etc/vpn/api.env"):
        mode = os.stat("/etc/vpn/api.env").st_mode & 0o777
        checks.append({"name": "api-env-mode", "ok": mode == 0o600, "detail": oct(mode)})
    listening = _listening()
    for name, proto, port in (("ssh", "tcp", 22), ("openvpn-tcp", "tcp", 1194), ("openvpn-udp", "udp", 1194)):
        checks.append({"name": f"port:{name}", "ok": port in listening.get(proto, set()),
                       "detail": "listening" if port in listening.get(proto, set()) else "not listening"})
    system_accounts = set()
    xray_accounts = set()
    try:
        passwd = subprocess.run(["getent", "passwd"], text=True, capture_output=True, check=True).stdout
        system_accounts = {line.split(":", 1)[0] for line in passwd.splitlines()}
    except (OSError, subprocess.CalledProcessError): pass
    try:
        with open(xray_path, encoding="utf-8") as stream: config = json.load(stream)
        for inbound in config.get("inbounds", []):
            protocol = inbound.get("protocol")
            if protocol in ("vmess", "vless", "trojan"):
                xray_accounts.update((protocol, client.get("email")) for client in inbound.get("settings", {}).get("clients", []) if client.get("email"))
    except (OSError, ValueError): pass
    orphaned = []
    for row in registry.list(limit=1000):
        if row["service"] == "ssh" and row["username"] not in system_accounts: orphaned.append(f"ssh/{row['username']}")
        elif row["service"] in ("vmess", "vless", "trojan") and (row["service"], row["username"]) not in xray_accounts: orphaned.append(f"{row['service']}/{row['username']}")
        elif row["service"].startswith("ovpn-"):
            proto = row["service"][5:]
            if not os.path.isfile(f"/etc/openvpn/clients/{row['username']}-{proto}.ovpn"):
                orphaned.append(f"{row['service']}/{row['username']}")
    checks.append({"name": "registry-system-consistency", "ok": not orphaned,
                   "detail": "consistent" if not orphaned else f"orphaned registry entries: {', '.join(orphaned)}"})
    return {"ok": all(item["ok"] for item in checks), "checks": checks, "accounts": registry.count_by_service()}


def _listening():
    result = {"tcp": set(), "udp": set()}
    for proto, path in (("tcp", "/proc/net/tcp"), ("tcp", "/proc/net/tcp6"), ("udp", "/proc/net/udp"), ("udp", "/proc/net/udp6")):
        try:
            with open(path, encoding="utf-8") as stream:
                for line in stream.readlines()[1:]:
                    fields = line.split()
                    if len(fields) > 3 and (proto != "tcp" or fields[3] == "0A"):
                        result[proto].add(int(fields[1].split(":")[1], 16))
        except OSError: pass
    return result
