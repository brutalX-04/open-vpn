import multiprocessing
import os
import uuid
from concurrent.futures import ThreadPoolExecutor

import pytest

from vpnctl.registry import ConflictError, Registry
from vpnctl.cli import rotate_api_key
from vpnctl.timeutil import expires_after, iso_utc
from vpnctl.validate import ValidationError, validate_duration, validate_password, validate_username
from vpnctl.migrate import migrate_ovpn, migrate_ssh, migrate_xray
from vpnctl.drivers.xray import XrayDriver
from vpnctl.doctor import doctor
import json


def _add_many(path, index):
    Registry(path).add("ssh", f"user{index:02d}", 100, 200)


def test_validation():
    assert validate_username("abc_1", "vmess") == "abc_1"
    for name in ("Abc", "a;id", "ab", "contains space"):
        with pytest.raises(ValidationError):
            validate_username(name)
    with pytest.raises(ValidationError):
        validate_username("admin", "ssh")
    assert validate_duration(days=30) == 30
    assert validate_duration(hours=720) == 720
    for kwargs in ({"days": 0}, {"days": 31}, {"hours": 721}, {"days": 1, "hours": 2}, {}):
        with pytest.raises(ValidationError):
            validate_duration(**kwargs)
    assert validate_password("long-enough")
    with pytest.raises(ValidationError):
        validate_password("short")


def test_api_key_rotation_preserves_settings():
    path = os.path.join(os.getcwd(), f".api-env-{uuid.uuid4().hex}")
    try:
        with open(path, "w", encoding="utf-8") as stream:
            stream.write("API_KEY=old\nDOMAIN=vpn.example.test\nAPI_DOCS=0\n")
        key = rotate_api_key(path)
        with open(path, encoding="utf-8") as stream:
            values = dict(line.split("=", 1) for line in stream.read().splitlines())
        assert values["API_KEY"] == key and key != "old"
        assert values["DOMAIN"] == "vpn.example.test"
        assert values["API_DOCS"] == "0"
    finally:
        try: os.remove(path)
        except FileNotFoundError: pass


def test_xray_remove_uses_inbound_tag_and_email(monkeypatch):
    captured = {}
    class Result:
        returncode = 0
        stdout = "Removed 1 user(s)"
        stderr = ""
    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        return Result()
    monkeypatch.setattr("vpnctl.drivers.xray.subprocess.run", fake_run)
    XrayDriver(api_server="127.0.0.1:10085")._runtime(
        "rmu", {"tag": "vmess-ws"}, {"email": "codexvmtest"})
    assert captured["argv"] == ["xray", "api", "rmu", "--server=127.0.0.1:10085",
                                "--tag=vmess-ws", "codexvmtest"]


def test_expiry_math_and_iso():
    assert expires_after(days=1, now=123) == 123 + 86400
    assert expires_after(hours=3, now=123) == 123 + 10800
    assert iso_utc(0) == "1970-01-01T00:00:00Z"


def test_doctor_warns_when_crl_nears_expiry(monkeypatch):
    import subprocess
    from datetime import datetime, timezone

    crl_path = "/etc/openvpn/crl.pem"
    original_exists = os.path.exists
    monkeypatch.setattr("vpnctl.doctor.os.path.exists", lambda path: path == crl_path or original_exists(path))
    monkeypatch.setattr("vpnctl.doctor._command", lambda *args: (True, "nextUpdate=Oct 16 12:00:00 2026 GMT")
                        if args[0] == "openssl" and args[1] == "crl" else (True, "active"))
    monkeypatch.setattr("vpnctl.doctor._listening", lambda: {"tcp": set(), "udp": set()})
    monkeypatch.setattr(subprocess, "run", lambda *args, **kwargs: subprocess.CompletedProcess(args[0], 0, "", ""))
    class EmptyRegistry:
        def list(self, limit=1000): return []
        def count_by_service(self): return {}

    result = doctor(EmptyRegistry(), now=datetime(2026, 10, 6, 12, tzinfo=timezone.utc))
    check = next(item for item in result["checks"] if item["name"] == "openvpn-crl")
    assert check["ok"] is False
    assert "10 days remain" in check["detail"]


def test_registry_lifecycle_and_idempotency():
    path = os.path.join(os.getcwd(), f".test-registry-{uuid.uuid4().hex}.db")
    try:
        registry = Registry(path)
        account = registry.add("ssh", "abc", 100, 200, meta={"x": 1})
        assert registry.get("ssh", "abc") == account
        assert registry.expired(200) == [account]
        assert registry.count_by_service() == {"ssh": 1}
        assert registry.renew("ssh", "abc", 300)["expires_at"] == 300
        assert registry.list("ssh")[0]["username"] == "abc"
        registry.save_idempotency("key", "hash", {"ok": True}, created_at=1000)
        assert registry.get_idempotency("key", now=1001)["response"] == {"ok": True}
        assert registry.get_idempotency("key", now=87401) is None
        with pytest.raises(ConflictError):
            registry.add("ssh", "abc", 1, 2)
        assert registry.remove("ssh", "abc")
        assert not registry.remove("ssh", "abc")
    finally:
        for suffix in ("", "-wal", "-shm"):
            try:
                os.remove(path + suffix)
            except FileNotFoundError:
                pass


def test_concurrent_adds():
    path = os.path.join(os.getcwd(), f".test-registry-{uuid.uuid4().hex}.db")
    try:
        Registry(path)
        if os.name == "nt":
            # The managed Windows test sandbox blocks multiprocessing named pipes.
            with ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(lambda i: _add_many(path, i), range(20)))
        else:
            with multiprocessing.get_context("spawn").Pool(8) as pool:
                pool.starmap(_add_many, [(path, i) for i in range(20)])
        rows = Registry(path).list(limit=100)
        assert len(rows) == 20
        assert len({(row["service"], row["username"]) for row in rows}) == 20
    finally:
        for suffix in ("", "-wal", "-shm"):
            try:
                os.remove(path + suffix)
            except FileNotFoundError:
                pass


def test_legacy_migration_is_idempotent():
    stem = os.path.join(os.getcwd(), f".migration-{uuid.uuid4().hex}")
    db = stem + ".db"
    passwd, shadow, config, clients = stem + ".passwd", stem + ".shadow", stem + ".json", stem + "-clients"
    os.mkdir(clients)
    try:
        with open(passwd, "w", encoding="utf-8") as stream:
            stream.write("legacy_ssh:x:1001:1001::/home/legacy_ssh:/bin/false\n")
        with open(shadow, "w", encoding="utf-8") as stream:
            stream.write("legacy_ssh:!:1:0:99999:7::20000:\n")
        with open(config, "w", encoding="utf-8") as stream:
            json.dump({"inbounds": [
                {"protocol": "vmess", "settings": {"clients": [{"email": "legacy_vmess", "comment": "legacy_vmess 2030-01-02"}]}},
                {"protocol": "vless", "settings": {"clients": [{"email": "legacy_vless", "comment": "legacy_vless 2000000000"}]}}
            ]}, stream)
        with open(os.path.join(clients, "legacy_ovpn-tcp.ovpn"), "w", encoding="utf-8") as stream:
            stream.write("# Expired: 2030-01-02 12:30:00\n")
        registry = Registry(db)
        assert migrate_ssh(registry, passwd, shadow, now=100)["legacy_ssh"] == "imported"
        xray_result = migrate_xray(registry, config, now=100)
        assert xray_result["vmess/legacy_vmess"] == "imported"
        assert xray_result["vless/legacy_vless"] == "imported"
        assert migrate_ovpn(registry, clients, now=100)["ovpn-tcp/legacy_ovpn"] == "imported"
        assert migrate_xray(registry, config, now=100)["vmess/legacy_vmess"] == "skipped_duplicate"
        assert registry.count_by_service() == {"ovpn-tcp": 1, "ssh": 1, "vless": 1, "vmess": 1}
    finally:
        for path in (passwd, shadow, config):
            try: os.remove(path)
            except FileNotFoundError: pass
        for path in (os.path.join(clients, "legacy_ovpn-tcp.ovpn"), clients):
            try:
                if os.path.isdir(path): os.rmdir(path)
                else: os.remove(path)
            except FileNotFoundError: pass
        for suffix in (".db", ".db-wal", ".db-shm"):
            try: os.remove(stem + suffix)
            except FileNotFoundError: pass

