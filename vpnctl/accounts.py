"""Shared account orchestration for API, CLI, and cleanup."""
import base64
import os
import secrets

from .drivers.dryrun import DryRunDriver
from .drivers.ovpn import OpenVPNDriver
from .drivers.ssh import SSHDriver
from .drivers.xray import XrayDriver
from .locking import ops_lock
from .registry import Registry
from .timeutil import expires_after, utc_now
from .validate import SERVICES, validate_duration, validate_password, validate_username


class AccountManager:
    def __init__(self, registry=None, drivers=None, lock_path=None):
        self.registry = registry or Registry()
        self.lock_path = lock_path
        dry = os.environ.get("VPN_DRY_RUN") == "1"
        config = {}
        try:
            with open("/etc/vpn/config.conf", encoding="utf-8") as stream:
                for line in stream:
                    if "=" in line and not line.startswith("#"):
                        key, value = line.rstrip("\n").split("=", 1)
                        config[key] = value.strip()
        except OSError:
            pass
        domain = config.get("DOMAIN", "localhost")
        ip = config.get("IP", "127.0.0.1")
        ports = {"tcp": int(config.get("PORT_OVPN_TCP", "1194")), "udp": int(config.get("PORT_OVPN_UDP", "1194"))}
        if drivers is not None:
            self.drivers = drivers
        elif dry:
            dry_driver = DryRunDriver()
            self.drivers = {service: dry_driver for service in SERVICES}
        else:
            self.drivers = {
                "ssh": SSHDriver(dry),
                **{name: XrayDriver(dry_run=dry) for name in ("vmess", "vless", "trojan")},
                "ovpn-tcp": OpenVPNDriver(domain=domain, ip=ip, ports=ports, dry_run=dry),
                "ovpn-udp": OpenVPNDriver(domain=domain, ip=ip, ports=ports, dry_run=dry),
            }

    @staticmethod
    def _new_username():
        alphabet = "abcdefghijklmnopqrstuvwxyz234567"
        return "u" + "".join(secrets.choice(alphabet) for _ in range(8))

    def create(self, service, username=None, days=None, hours=None, password=None, max_sessions=1):
        if service not in SERVICES:
            raise ValueError("unsupported service")
        duration = validate_duration(days=days, hours=hours)
        validate_username(username, service) if username else None
        if username is None:
            username = self._new_username()
        if service == "ssh":
            try:
                import pwd
                pwd.getpwnam(username)
            except (ImportError, KeyError):
                pass
            else:
                raise ValueError("SSH username already exists on this system")
            if not password:
                password = base64.urlsafe_b64encode(os.urandom(9)).decode().rstrip("=")
            validate_password(password)
        if isinstance(max_sessions, bool) or not isinstance(max_sessions, int) or not 1 <= max_sessions <= 100:
            raise ValueError("max_sessions must be between 1 and 100")
        now = utc_now()
        expiry = expires_after(days=duration, now=now) if days is not None else expires_after(hours=duration, now=now)
        meta = {}
        with ops_lock(self.lock_path):
            if self.registry.get(service, username):
                raise ValueError("account already exists")
            driver = self.drivers[service]
            try:
                meta = driver.create(service=service, username=username, password=password, expires_at=expiry, days=days, hours=hours)
                safe_meta = {key: value for key, value in meta.items()
                             if key not in {"password", "uuid", "content", "_created_certificate"}}
                row = self.registry.add(service, username, now, expiry, max_sessions, safe_meta)
            except Exception:
                if meta:
                    try:
                        rollback = getattr(driver, "rollback_create", None)
                        if rollback: rollback(service=service, username=username, meta=meta)
                        else: driver.delete(service=service, username=username)
                    except Exception: pass
                raise
        public_meta = {key: value for key, value in meta.items() if not key.startswith("_")}
        return {"service": service, "username": username, "created_at": now, "expires_at": expiry,
                "max_sessions": max_sessions, "meta": public_meta}

    def delete(self, service, username):
        validate_username(username, service)
        with ops_lock(self.lock_path):
            row = self.registry.get(service, username)
            if row is None: return False
            driver = self.drivers[service]
            if service.startswith("ovpn-"):
                sibling = "ovpn-udp" if service == "ovpn-tcp" else "ovpn-tcp"
                has_sibling = bool(self.registry.get(sibling, username))
                if not has_sibling:
                    driver.disconnect(service=service, username=username, all_protocols=True)
                    driver.delete(service=service, username=username)
                else:
                    driver.disconnect(service=service, username=username, all_protocols=False)
                    proto = service[5:]
                    try: os.unlink(os.path.join("/etc/openvpn/clients", f"{username}-{proto}.ovpn"))
                    except FileNotFoundError: pass
            else:
                driver.disconnect(service=service, username=username)
                driver.delete(service=service, username=username)
            return self.registry.remove(service, username)

    def renew(self, service, username, days):
        validate_username(username, service)
        validate_duration(days=days)
        if service.startswith("ovpn-"):
            raise NotImplementedError("OpenVPN certificates cannot be renewed")
        with ops_lock(self.lock_path):
            row = self.registry.get(service, username)
            if row is None: return None
            expiry = max(row["expires_at"], utc_now()) + days * 86400
            driver = self.drivers[service]
            driver.renew(service=service, username=username, expires_at=expiry)
            try:
                return self.registry.renew(service, username, expiry)
            except Exception:
                try: driver.renew(service=service, username=username, expires_at=row["expires_at"])
                except Exception: pass
                raise

    def cleanup(self, now=None):
        removed = []
        ovpn_revoked = False
        with ops_lock(self.lock_path, timeout=0.2):
            for row in self.registry.expired(now):
                service, username = row["service"], row["username"]
                driver = self.drivers[service]
                if service.startswith("ovpn-"):
                    sibling = "ovpn-udp" if service == "ovpn-tcp" else "ovpn-tcp"
                    has_sibling = bool(self.registry.get(sibling, username))
                    if not has_sibling:
                        driver.disconnect(service=service, username=username, all_protocols=True)
                        driver.delete(service=service, username=username, refresh_crl=False)
                        ovpn_revoked = True
                    else:
                        driver.disconnect(service=service, username=username, all_protocols=False)
                        proto = service[5:]
                        try: os.unlink(os.path.join("/etc/openvpn/clients", f"{username}-{proto}.ovpn"))
                        except FileNotFoundError: pass
                else:
                    driver.disconnect(service=service, username=username)
                    driver.delete(service=service, username=username)
                removed.append(row)
            if ovpn_revoked:
                next(driver for name, driver in self.drivers.items() if name.startswith("ovpn-")).refresh_crl()
            for row in removed:
                self.registry.remove(row["service"], row["username"])
        return removed

