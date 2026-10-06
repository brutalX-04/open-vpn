"""SSH account operations use argv-only system commands."""
import subprocess
from datetime import datetime, timezone

from .base import Driver


def _run(argv, *, input_text=None, check=True):
    result = subprocess.run(argv, input=input_text, text=True, capture_output=True, check=False)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or f"command failed: {argv[0]}")
    return result


class SSHDriver(Driver):
    def __init__(self, dry_run=False):
        self.dry_run = dry_run

    def create(self, username, password, expires_at, **kwargs):
        if self.dry_run:
            return {"password": password}
        expires = datetime.fromtimestamp(expires_at + 86400, timezone.utc).date()
        _run(["useradd", "-M", "-s", "/bin/false", "-e", expires.isoformat(), username])
        try:
            _run(["chpasswd"], input_text=f"{username}:{password}\n")
        except Exception:
            _run(["userdel", "--force", username], check=False)
            raise
        return {"password": password}

    def delete(self, username, **kwargs):
        if self.dry_run:
            return {}
        _run(["pkill", "-KILL", "-u", username], check=False)
        _run(["userdel", "--force", username], check=False)
        return {}

    def renew(self, username, expires_at, **kwargs):
        if not self.dry_run:
            date = datetime.fromtimestamp(expires_at + 86400, timezone.utc).date().isoformat()
            _run(["usermod", "-e", date, username])
        return {}

    def disconnect(self, username, **kwargs):
        if not self.dry_run:
            _run(["pkill", "-KILL", "-u", username], check=False)
        return {}

    def count_online(self):
        result = _run(["ps", "-eo", "user=,args="], check=False)
        return sum(1 for line in result.stdout.splitlines() if "sshd:" in line or "dropbear" in line)
