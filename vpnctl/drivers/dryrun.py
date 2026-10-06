from .base import Driver
import uuid


class DryRunDriver(Driver):
    """Side-effect-free driver used by tests and development."""
    def create(self, *args, **kwargs):
        service = kwargs.get("service", args[0] if args else "")
        username = kwargs.get("username", "sample")
        if service == "ssh": return {"password": kwargs.get("password", "dry-run-password")}
        if service in ("vmess", "vless"): return {"uuid": str(uuid.uuid4())}
        if service == "trojan": return {"password": str(uuid.uuid4())}
        if service in ("ovpn-tcp", "ovpn-udp"):
            proto = service[5:]
            return {"filename": f"{username}-{proto}.ovpn", "content": "dry-run", "host": "localhost", "port": 1194, "proto": proto}
        return {"dry_run": True}

    def delete(self, *args, **kwargs):
        return {"dry_run": True}

    def renew(self, *args, **kwargs):
        return {"dry_run": True}

    def disconnect(self, *args, **kwargs):
        return {"dry_run": True}

    def count_online(self):
        return None
