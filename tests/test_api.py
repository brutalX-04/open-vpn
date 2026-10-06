import os
import uuid
from concurrent.futures import ThreadPoolExecutor

from fastapi.testclient import TestClient

from api.main import create_app
import api.main as api_main
from vpnctl.accounts import AccountManager
from vpnctl.registry import Registry


def test_api_contract_and_idempotency(monkeypatch):
    monkeypatch.setenv("VPN_DRY_RUN", "1")
    monkeypatch.setattr(api_main, "_unit_status", lambda units: {unit: "running" for unit in units})
    monkeypatch.setattr(api_main, "_port_listening", lambda port: True)
    monkeypatch.setattr(api_main, "_udp_port_listening", lambda port: True)
    db = os.path.join(os.getcwd(), f".api-registry-{uuid.uuid4().hex}.db")
    lock = os.path.join(os.getcwd(), f".api-lock-{uuid.uuid4().hex}")
    try:
        manager = AccountManager(Registry(db), lock_path=lock)
        app = create_app(manager=manager, api_key="test-api-key")
        client = TestClient(app)
        assert client.get("/v1/health").json() == {"data": {"ok": True}}
        assert client.get("/v1/status").status_code == 401
        assert client.get("/v1/status", headers={"X-API-Key": "wrong"}).status_code == 401
        headers = {"X-API-Key": "test-api-key"}
        assert client.get("/v1/services", headers=headers).status_code == 200
        assert client.get("/v1/status", headers=headers).status_code == 200
        invalid = client.post("/v1/accounts", headers=headers, json={"service": "ssh", "days": 2, "username": "a;touch"})
        assert invalid.status_code == 422
        created = client.post("/v1/accounts", headers={**headers, "Idempotency-Key": "test-1"},
                              json={"service": "ssh", "days": 2, "username": "user_one", "password": "safe-pass-123"})
        assert created.status_code == 201
        repeated = client.post("/v1/accounts", headers={**headers, "Idempotency-Key": "test-1"},
                               json={"service": "ssh", "days": 2, "username": "user_one", "password": "safe-pass-123"})
        assert repeated.status_code == 201
        conflict = client.post("/v1/accounts", headers={**headers, "Idempotency-Key": "test-1"},
                               json={"service": "ssh", "days": 3, "username": "user_two", "password": "safe-pass-123"})
        assert conflict.status_code == 409
        duplicate = client.post("/v1/accounts", headers=headers,
                                json={"service": "ssh", "days": 2, "username": "user_one", "password": "safe-pass-123"})
        assert duplicate.status_code == 409
        assert client.post("/v1/accounts/ssh/user_one/renew", headers=headers, json={"days": 2}).status_code == 200
        assert client.delete("/v1/accounts/ssh/user_one", headers=headers).status_code == 200
        ovpn = client.post("/v1/accounts", headers=headers, json={"service": "ovpn-tcp", "days": 2, "username": "user_vpn"})
        assert ovpn.status_code == 201
        assert ovpn.json()["data"]["connection"]["content"] == "dry-run"
        assert client.post("/v1/accounts/ovpn-tcp/user_vpn/renew", headers=headers, json={"days": 2}).status_code == 501
        assert client.delete("/v1/accounts/ovpn-tcp/user_vpn", headers=headers).status_code == 200
        assert client.get("/v1/accounts/ssh/missing_user", headers=headers).status_code == 404
        unavailable = client.post("/v1/accounts", headers=headers, json={"service": "vless", "days": 2, "username": "user_two"})
        assert unavailable.status_code == 503
        assert client.get("/v1/services", headers=headers).json()["data"]["services"][1]["available"] is False
        assert "X-Request-Id" in client.get("/v1/health").headers
    finally:
        for path in (db, db + "-wal", db + "-shm", lock):
            try: os.remove(path)
            except FileNotFoundError: pass


def test_tcp_listener_helper_uses_string_port_key(monkeypatch):
    monkeypatch.setattr(api_main, "_listening_ports", lambda ports: {str(port): True for port in ports})
    assert api_main._port_listening(22) is True
    monkeypatch.setattr(api_main, "_listening_ports", lambda ports: {str(port): False for port in ports})
    assert api_main._port_listening(22) is False

