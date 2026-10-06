"""Idempotent import of legacy account metadata into the registry."""
import json
import os
import re
import subprocess
from datetime import datetime, timezone

from .registry import ConflictError
from .timeutil import utc_now
from .validate import ValidationError, validate_username


def _timestamp(value):
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d"):
        try:
            return int(datetime.strptime(value, fmt).replace(tzinfo=timezone.utc).timestamp())
        except ValueError:
            continue
    return None


def _add(registry, service, username, expiry, meta=None, now=None):
    try:
        validate_username(username, service)
    except ValidationError:
        return "skipped_invalid_username"
    try:
        registry.add(service, username, utc_now() if now is None else now, expiry, meta=meta or {})
        return "imported"
    except ConflictError:
        return "skipped_duplicate"


def migrate_ssh(registry, passwd_path="/etc/passwd", shadow_path="/etc/shadow", now=None):
    """Import eligible shadow accounts with a valid account expiry field."""
    expiries = {}
    try:
        with open(shadow_path, encoding="utf-8") as stream:
            for line in stream:
                fields = line.rstrip("\n").split(":")
                if len(fields) > 7 and fields[7].isdigit():
                    expiries[fields[0]] = int(fields[7]) * 86400
    except OSError:
        pass
    results = {}
    try:
        with open(passwd_path, encoding="utf-8") as stream:
            for line in stream:
                fields = line.rstrip("\n").split(":")
                if len(fields) < 7 or not fields[2].isdigit() or int(fields[2]) < 1000 or fields[6] != "/bin/false":
                    continue
                username = fields[0]
                if username not in expiries:
                    results[username] = "skipped_no_expiry"
                    continue
                results[username] = _add(registry, "ssh", username, expiries[username], now=now)
    except OSError:
        pass
    return results


def migrate_xray(registry, config_path="/etc/xray/config.json", now=None):
    results = {}
    try:
        with open(config_path, encoding="utf-8") as stream:
            config = json.load(stream)
    except (OSError, ValueError):
        return results
    for inbound in config.get("inbounds", []):
        proto = inbound.get("protocol") or inbound.get("tag", "").split("-")[0]
        if proto not in {"vmess", "vless", "trojan"}:
            continue
        for client in inbound.get("settings", {}).get("clients", []):
            comment = client.get("comment", "")
            match = re.search(r"(?:^|\s)(\d{4}-\d{2}-\d{2}(?:\s+\d{2}:\d{2}:\d{2})?)$", comment)
            username = client.get("email")
            epoch_match = re.search(r"(?:^|\s)(\d{9,12})$", comment)
            expiry = int(epoch_match.group(1)) if epoch_match else (_timestamp(match.group(1)) if match else None)
            if not username or expiry is None:
                continue
            results[f"{proto}/{username}"] = _add(registry, proto, username, expiry, {"legacy_comment": comment}, now)
    return results


def migrate_ovpn(registry, client_dir="/etc/openvpn/clients", now=None):
    results = {}
    try:
        paths = os.listdir(client_dir)
    except OSError:
        return results
    for filename in paths:
        match = re.fullmatch(r"([a-z][a-z0-9_]{2,19})-(tcp|udp)\.ovpn", filename)
        if not match:
            continue
        path = os.path.join(client_dir, filename)
        try:
            with open(path, encoding="utf-8") as stream:
                content = stream.read(65536)
        except OSError:
            continue
        expiry_match = re.search(r"^# Expired:\s*(.+)$", content, re.M)
        expiry = _timestamp(expiry_match.group(1)) if expiry_match else None
        if expiry is None:
            continue
        username, proto = match.groups()
        results[f"ovpn-{proto}/{username}"] = _add(registry, f"ovpn-{proto}", username, expiry, {"profile": filename}, now)
    return results
