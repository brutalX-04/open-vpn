"""OpenVPN Easy-RSA account operations without daemon restarts."""
import os
import socket
import subprocess
import math
import time
from datetime import datetime, timezone

from .base import Driver


class OpenVPNDriver(Driver):
    def __init__(self, easy_rsa="/etc/openvpn/easy-rsa", clients="/etc/openvpn/clients", domain="localhost", ip="127.0.0.1", ports=None, dry_run=False):
        self.easy_rsa, self.clients, self.domain, self.ip = easy_rsa, clients, domain, ip
        self.ports, self.dry_run = ports or {"tcp": 1194, "udp": 1194}, dry_run

    def _run(self, *args, env=None):
        run_env = os.environ.copy()
        if env: run_env.update(env)
        return subprocess.run(["./easyrsa", "--batch", *args], cwd=self.easy_rsa, env=run_env, capture_output=True, text=True, check=True)

    def create(self, service, username, expires_at, **kwargs):
        proto = "tcp" if service == "ovpn-tcp" else "udp"
        filename = f"{username}-{proto}.ovpn"
        path = os.path.join(self.clients, filename)
        if self.dry_run: return {"filename": filename, "content": "", "_created_certificate": False}
        if os.path.exists(path): raise FileExistsError(f"OpenVPN profile already exists: {filename}")
        for required in (os.path.join(self.easy_rsa, "pki", "ca.crt"), "/etc/openvpn/ta.key"):
            if not os.path.isfile(required): raise FileNotFoundError(f"required OpenVPN file missing: {required}")
        created_certificate = False
        if not (os.path.exists(os.path.join(self.easy_rsa, "pki", "issued", username + ".crt")) and os.path.exists(os.path.join(self.easy_rsa, "pki", "private", username + ".key"))):
            reserve_days = max(2, math.ceil(max(1, expires_at - int(time.time())) / 86400) + 1)
            self._run("build-client-full", username, "nopass", env={"EASYRSA_CERT_EXPIRE": str(reserve_days)})
            created_certificate = True
        if created_certificate and not (os.path.isfile(os.path.join(self.easy_rsa, "pki", "issued", username + ".crt")) and
                                        os.path.isfile(os.path.join(self.easy_rsa, "pki", "private", username + ".key"))):
            try: self.delete(username)
            except Exception: pass
            raise RuntimeError("Easy-RSA did not create the client certificate and key")
        expires = datetime.fromtimestamp(expires_at, timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        ca = open(os.path.join(self.easy_rsa, "pki", "ca.crt"), encoding="utf-8").read().strip()
        cert = open(os.path.join(self.easy_rsa, "pki", "issued", username + ".crt"), encoding="utf-8").read().strip()
        key = open(os.path.join(self.easy_rsa, "pki", "private", username + ".key"), encoding="utf-8").read().strip()
        tls = open("/etc/openvpn/ta.key", encoding="utf-8").read().strip()
        host = self.domain if self.domain and self.domain != "localhost" else self.ip
        content = f"client\ndev tun\nproto {proto}\nremote {host} {self.ports[proto]}\nresolv-retry infinite\nnobind\npersist-key\npersist-tun\nremote-cert-tls server\nauth SHA512\ncipher AES-256-CBC\nkey-direction 1\nverb 3\n\n# Expired: {expires}\n<ca>\n{ca}\n</ca>\n<cert>\n{cert}\n</cert>\n<key>\n{key}\n</key>\n<tls-auth>\n{tls}\n</tls-auth>\n"
        os.makedirs(self.clients, exist_ok=True)
        from ..locking import atomic_write
        try:
            atomic_write(path, content, mode=0o600)
        except Exception:
            if created_certificate:
                try: self.delete(username)
                except Exception: pass
            raise
        return {"filename": filename, "content": content, "port": self.ports[proto], "proto": proto, "host": host,
                "_created_certificate": created_certificate}

    def rollback_create(self, username, meta, **kwargs):
        if self.dry_run: return
        filename = meta.get("filename")
        if filename:
            try: os.unlink(os.path.join(self.clients, filename))
            except FileNotFoundError: pass
        if meta.get("_created_certificate"):
            self.delete(username, refresh_crl=True)

    def _management(self, proto, command):
        sock_path = f"/run/openvpn/{proto}.sock"
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.settimeout(2); sock.connect(sock_path); sock.recv(4096)
            sock.sendall((command + "\n").encode()); return sock.recv(4096).decode(errors="replace")
        finally: sock.close()

    def disconnect(self, username, service=None, all_protocols=True, **kwargs):
        if self.dry_run: return {}
        protocols = ("tcp", "udp") if all_protocols else ((service[5:],) if service and service.startswith("ovpn-") else ("tcp", "udp"))
        for proto in protocols:
            try: self._management(proto, f"kill {username}")
            except OSError: pass
        return {}

    def delete(self, username, refresh_crl=True, **kwargs):
        if self.dry_run: return {}
        index_path = os.path.join(self.easy_rsa, "pki", "index.txt")
        already_revoked = False
        try:
            with open(index_path, encoding="utf-8") as index:
                already_revoked = any(line.startswith("R") and f"/CN={username}" in line for line in index)
        except OSError: pass
        if not already_revoked: self._run("revoke", username)
        for proto in ("tcp", "udp"):
            try: os.unlink(os.path.join(self.clients, f"{username}-{proto}.ovpn"))
            except FileNotFoundError: pass
        if refresh_crl: self.refresh_crl()
        return {}

    def refresh_crl(self):
        if self.dry_run: return
        self._run("gen-crl")
        import shutil
        shutil.copyfile(os.path.join(self.easy_rsa, "pki", "crl.pem"), "/etc/openvpn/crl.pem")
        os.chmod("/etc/openvpn/crl.pem", 0o644)

    def renew(self, *args, **kwargs): raise NotImplementedError("OpenVPN certificates are not renewable; create a new account")
    def count_online(self): return None
