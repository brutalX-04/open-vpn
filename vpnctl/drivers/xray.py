"""Xray config driver. Runtime mutation must succeed before committing state."""
import json
import os
import re
import subprocess
import tempfile
import uuid

from ..locking import atomic_write
from .base import Driver


class XrayDriver(Driver):
    def __init__(self, config_path="/etc/xray/config.json", api_server="127.0.0.1:10085", dry_run=False):
        self.config_path, self.api_server, self.dry_run = config_path, api_server, dry_run

    def _config(self):
        with open(self.config_path, encoding="utf-8") as stream:
            return json.load(stream)

    def _save(self, config):
        atomic_write(self.config_path, json.dumps(config, indent=2) + "\n")

    def _runtime(self, action, inbound_config, client):
        if action == "rmu":
            tag = inbound_config.get("tag")
            email = client.get("email")
            if not tag or not email:
                raise RuntimeError("Xray inbound tag and client email are required for removal")
            result = subprocess.run(
                ["xray", "api", "rmu", f"--server={self.api_server}", f"--tag={tag}", email],
                capture_output=True, text=True,
            )
            if result.returncode:
                raise RuntimeError(result.stderr.strip() or "Xray runtime API rejected the client removal")
            count = re.search(r"Removed\s+(\d+)\s+user\(s\)", result.stdout)
            if count and int(count.group(1)) != 1:
                raise RuntimeError("Xray runtime API removed an unexpected number of users")
            return
        # Xray's adu command reads a normal config-shaped JSON document and
        # forwards the new user to HandlerService.
        runtime_client = {key: value for key, value in client.items() if key != "comment"}
        inbound = json.loads(json.dumps(inbound_config))
        inbound.setdefault("settings", {})["clients"] = [runtime_client]
        request = {"inbounds": [inbound]}
        temp = tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False)
        try:
            json.dump(request, temp)
            temp.close()
            result = subprocess.run(["xray", "api", action, f"--server={self.api_server}", temp.name], capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError(result.stderr.strip() or "Xray runtime API rejected the client change")
            if "Added 0 user(s)" in result.stdout:
                raise RuntimeError("Xray runtime API did not apply the client change")
            count = re.search(r"Added\s+(\d+)\s+user\(s\)", result.stdout)
            if count and int(count.group(1)) != 1:
                raise RuntimeError("Xray runtime API applied an unexpected number of user changes")
        finally:
            try: os.unlink(temp.name)
            except OSError: pass

    def create(self, service, username, expires_at, **kwargs):
        client_id = str(uuid.uuid4())
        if self.dry_run:
            return {"uuid": client_id}
        config = self._config()
        target = next((item for item in config.get("inbounds", []) if item.get("protocol") == service), None)
        if not target:
            raise RuntimeError(f"Xray inbound for {service} is unavailable")
        clients = target.setdefault("settings", {}).setdefault("clients", [])
        if any(item.get("email") == username for item in clients):
            raise ValueError("username already exists in Xray")
        credential = client_id
        entry = {"email": username, "comment": f"{username} {int(expires_at)}"}
        if service == "trojan":
            entry["password"] = credential
        else:
            entry["id"] = credential
            if service == "vmess": entry["alterId"] = 0
            if service == "vless": entry["flow"] = ""
        clients.append(entry)
        old = json.dumps(self._config(), indent=2) + "\n"
        self._save(config)
        try:
            self._runtime("adu", target, entry)
        except Exception:
            atomic_write(self.config_path, old)
            raise
        return {"uuid" if service != "trojan" else "password": credential}

    def delete(self, service, username, **kwargs):
        if self.dry_run: return {}
        config = self._config()
        found = None
        inbound_config = None
        for inbound in config.get("inbounds", []):
            if inbound.get("protocol") == service:
                clients = inbound.get("settings", {}).get("clients", [])
                found = next((c for c in clients if c.get("email") == username), None)
                if found:
                    inbound["settings"]["clients"] = [c for c in clients if c.get("email") != username]
                    inbound_config = inbound
                    break
        if not found: return {}
        old = json.dumps(self._config(), indent=2) + "\n"
        self._save(config)
        try: self._runtime("rmu", inbound_config, found)
        except Exception:
            atomic_write(self.config_path, old)
            raise
        return {}

    def renew(self, service, username, expires_at, **kwargs):
        if self.dry_run: return {}
        config = self._config()
        for inbound in config.get("inbounds", []):
            if inbound.get("protocol") == service:
                for client in inbound.get("settings", {}).get("clients", []):
                    if client.get("email") == username:
                        client["comment"] = f"{username} {int(expires_at)}"
                        self._save(config)
                        return {}
        raise LookupError("Xray client not found")

    def disconnect(self, username, **kwargs): return {}
    def count_online(self): return None
