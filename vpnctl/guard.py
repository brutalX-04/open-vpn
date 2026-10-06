"""Lightweight account session enforcement for SSH and OpenVPN."""
import csv
import os
import re
import signal
import socket
import subprocess
import time

from .registry import Registry


def _ssh_session_username(args):
    # OpenSSH uses `user@notty` for some sessions, but on Ubuntu 24.04 it
    # names no-PTY tunnels `sshd: user`. Exclude the separate `[priv]` process.
    match = re.search(r"sshd:\s+([a-z][a-z0-9_]{2,19})(?:@|$)", args)
    return match.group(1) if match else None


def _management(proto):
    path = f"/run/openvpn/{proto}.sock"
    if not hasattr(socket, "AF_UNIX"):
        raise OSError("OpenVPN management sockets require Unix")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(3)
        sock.connect(path)
        sock.recv(4096)
        sock.sendall(b"status 3\n")
        data = b""
        while len(data) < 1024 * 1024:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
            if b"END\r\n" in data or b"END\n" in data:
                break
        return data.decode(errors="replace")
    finally:
        sock.close()


def openvpn_sessions():
    sessions = []
    for proto in ("tcp", "udp"):
        try:
            output = _management(proto)
        except OSError:
            continue
        for line in output.splitlines():
            if not (line.startswith("CLIENT_LIST,") or line.startswith("CLIENT_LIST\t")):
                continue
            delimiter = "\t" if "\t" in line else ","
            fields = next(csv.reader([line], delimiter=delimiter))
            # OpenVPN status-version 3 CLIENT_LIST schema:
            # ... Connected Since, Connected Since (time_t), Username,
            # Client ID, Peer ID, Data Channel Cipher.
            if len(fields) < 11:
                continue
            try: connected = int(fields[8])
            except ValueError: connected = 0
            sessions.append({"username": fields[1], "proto": proto, "connected": connected,
                             "client_id": fields[10]})
    return sessions


def _terminate_ssh_overages(registry, limits=None):
    result = subprocess.run(["ps", "-eo", "pid=,etimes=,user=,args="], text=True, capture_output=True)
    grouped = {}
    for line in result.stdout.splitlines():
        match = re.match(r"\s*(\d+)\s+(\d+)\s+(\S+)\s+(.+)", line)
        if not match: continue
        pid, elapsed, owner, args = int(match.group(1)), int(match.group(2)), match.group(3), match.group(4)
        session_user = _ssh_session_username(args)
        user = session_user or (owner if "dropbear" in args and owner != "root" else None)
        if user:
            grouped.setdefault(user, []).append((elapsed, pid))
    for row in registry.list(limit=1000):
        if row["service"] != "ssh": continue
        max_sessions = int((limits or {}).get(row["username"], (limits or {}).get("__default__", row["max_sessions"] or 1)))
        pids = sorted(grouped.get(row["username"], []), reverse=True)
        for _, pid in pids[max_sessions:]:
            try: os.kill(pid, signal.SIGTERM)
            except ProcessLookupError: pass
            print(f"SESSION-LIMIT | service=ssh user={row['username']} action=kill reason=over_limit", flush=True)


def enforce_once(registry=None, limits=None):
    registry = registry or Registry()
    rows = [row for row in registry.list(limit=1000) if row["service"].startswith("ovpn-")]
    max_by_cn = {}
    for row in rows:
        max_by_cn[row["username"]] = min(max_by_cn.get(row["username"], 10**9), int((limits or {}).get(row["username"], (limits or {}).get("__default__", row["max_sessions"] or 1))))
    grouped = {}
    for item in openvpn_sessions():
        grouped.setdefault(item["username"], []).append(item)
    for username, items in grouped.items():
        maximum = max_by_cn.get(username, 1)
        # Most recent connection stays; older sessions are disconnected first.
        for item in sorted(items, key=lambda entry: entry["connected"])[:max(0, len(items) - maximum)]:
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(2); sock.connect(f"/run/openvpn/{item['proto']}.sock"); sock.recv(4096)
                sock.sendall(f"client-kill {item['client_id']}\n".encode()); sock.close()
                print(f"SESSION-LIMIT | service=ovpn-{item['proto']} user={username} action=kill reason=over_limit", flush=True)
            except OSError: pass
    _terminate_ssh_overages(registry, limits)


def run_guard(registry=None, interval=7):
    limits = {}
    reload_requested = False
    def reload_config(signum, frame):
        nonlocal reload_requested
        reload_requested = True
    signal.signal(signal.SIGHUP, reload_config)
    while True:
        if reload_requested:
            reload_requested = False
            limits = load_limits()
            interval = limits.pop("__interval__", interval)
        try: enforce_once(registry, limits)
        except Exception as exc: print(f"vpn-session-guard: {exc}", flush=True)
        time.sleep(interval)


def load_limits(path="/etc/vpn/limits.conf"):
    config = {}
    try:
        with open(path, encoding="utf-8") as stream:
            for line in stream:
                if "=" not in line or line.lstrip().startswith("#"): continue
                key, value = line.strip().split("=", 1)
                if key == "MAX_SESSIONS": config["__default__"] = int(value)
                elif key == "INTERVAL": config["__interval__"] = max(5, min(10, int(value)))
    except (OSError, ValueError): pass
    return config


if __name__ == "__main__":
    run_guard()

