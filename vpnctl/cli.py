#!/usr/bin/env python3
"""Command-line entry point for vpnctl."""
import argparse
import json
import os
import secrets
import stat
import sys
import subprocess

from .accounts import AccountManager
from .migrate import migrate_ovpn, migrate_ssh, migrate_xray
from .registry import Registry
from .locking import BusyError, ops_lock
from .locking import atomic_write


def rotate_api_key(path="/etc/vpn/api.env"):
    key = secrets.token_urlsafe(48)
    settings = {}
    try:
        with open(path, encoding="utf-8") as stream:
            for line in stream:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    name, value = line.split("=", 1)
                    settings[name.strip()] = value.strip()
    except FileNotFoundError:
        pass
    settings["API_KEY"] = key
    atomic_write(path, "".join(f"{name}={value}\n" for name, value in settings.items()), mode=0o600)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    return key


def main(argv=None):
    parser = argparse.ArgumentParser(description="VPN account registry CLI")
    parser.add_argument("action", choices=["list", "migrate", "create", "delete", "renew", "cleanup", "doctor", "api-key"])
    parser.add_argument("api_key_action", nargs="?")
    parser.add_argument("--service")
    parser.add_argument("--user")
    parser.add_argument("--password")
    parser.add_argument("--password-stdin", action="store_true")
    parser.add_argument("--days", type=int)
    parser.add_argument("--hours", type=int)
    parser.add_argument("--max-sessions", type=int, default=1)
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--rotate", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    registry = Registry()
    if args.action == "list":
        output = registry.list(args.service, args.limit, args.offset)
    else:
        if args.action == "migrate":
            with ops_lock():
                output = {"ssh": migrate_ssh(registry), "xray": migrate_xray(registry), "ovpn": migrate_ovpn(registry)}
        elif args.action == "create":
            if not args.service:
                parser.error("create requires --service")
            password = sys.stdin.readline().rstrip("\r\n") if args.password_stdin else args.password
            output = AccountManager(registry).create(args.service, args.user, args.days, args.hours, password, args.max_sessions)
        elif args.action == "delete":
            if not args.service or not args.user:
                parser.error("delete requires --service and --user")
            output = {"deleted": AccountManager(registry).delete(args.service, args.user)}
        elif args.action == "renew":
            if not args.service or not args.user or not args.days:
                parser.error("renew requires --service, --user, and --days")
            output = AccountManager(registry).renew(args.service, args.user, args.days)
        elif args.action == "cleanup":
            try:
                removed = AccountManager(registry).cleanup()
            except BusyError:
                removed = []
            if args.verbose:
                print(json.dumps({"status": "success", "data": {"removed": len(removed)}}, indent=2))
            elif removed:
                print(f"CLEANUP | removed={len(removed)}")
            return 0
        elif args.action == "doctor":
            from .doctor import doctor
            output = doctor(registry)
        else:
            if not args.rotate and args.api_key_action != "rotate":
                parser.error("api-key requires --rotate")
            key = rotate_api_key()
            if os.name == "posix":
                subprocess.run(["systemctl", "restart", "vpn-api.service"], check=True, capture_output=True, text=True)
            output = {"api_key": key}
    print(json.dumps({"status": "success", "data": output}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
