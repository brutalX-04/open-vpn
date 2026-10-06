#!/usr/bin/env python3
"""Print a client link only when a live TLS WebSocket route is configured."""
import sys

sys.path.insert(0, "/etc/vpn")

from api.main import _xray_connection, _xray_proxy_status
from api.settings import load_settings


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: connection-link.py <service> <username> <credential>")
    service, username, credential = sys.argv[1:]
    if service not in {"vmess", "vless", "trojan"}:
        raise SystemExit("unsupported Xray service")
    settings = load_settings()
    routes, _ = _xray_proxy_status(settings["xray_front_proxy"])
    if not routes.get(service, {}).get("ws_tls"):
        raise SystemExit("TLS WebSocket route is unavailable")
    key = "password" if service == "trojan" else "uuid"
    connection = _xray_connection(service, settings["domain"], {key: credential, "username": username}, routes)
    print(connection["links"]["ws_tls"])


if __name__ == "__main__":
    main()
