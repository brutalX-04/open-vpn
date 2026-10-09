"""FastAPI routes. API secrets and credential-bearing bodies are never logged."""
import hashlib
import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.exceptions import RequestValidationError

from .auth import valid_api_key
from .schemas import CreateAccount, RenewAccount
from .settings import load_settings
from vpnctl.accounts import AccountManager
from vpnctl.registry import ConflictError, Registry
from vpnctl.timeutil import iso_utc
from vpnctl.validate import validate_username

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
log = logging.getLogger("vpn.api")

# Public client-facing listener ports, grouped by transport protocol. Xray's
# internal loopback ports (10001-10003) are deliberately not advertised.
SERVICE_PORTS = {
    "ssh": {"tcp": [22, 80, 109, 143, 443, 447, 777], "udp": []},
    "vmess": {"tcp": [80, 443], "udp": []},
    "vless": {"tcp": [80, 443], "udp": []},
    "trojan": {"tcp": [80, 443], "udp": []},
    "ovpn-tcp": {"tcp": [1194], "udp": []},
    "ovpn-udp": {"tcp": [], "udp": [1194]},
}


def _supported_ports(service):
    ports = SERVICE_PORTS.get(service, {"tcp": [], "udp": []})
    return {protocol: list(values) for protocol, values in ports.items()}


def create_app(manager=None, api_key=None):
    settings = load_settings()
    app = FastAPI(title="VPN Control API", docs_url="/docs" if settings["api_docs"] else None,
                  redoc_url=None, openapi_url="/openapi.json" if settings["api_docs"] else None)
    app.state.manager = manager
    def get_manager():
        if app.state.manager is None:
            app.state.manager = AccountManager(registry=Registry(settings["registry_db"]))
        return app.state.manager
    app.state.api_key = settings["api_key"] if api_key is None else api_key
    app.state.domain = settings["domain"]
    app.state.xray_front_proxy = settings["xray_front_proxy"]
    app.state.status_cache = (0.0, None)

    @app.middleware("http")
    async def request_log(request: Request, call_next):
        request_id = request.headers.get("x-request-id") or str(uuid.uuid4())
        start = time.monotonic()
        response = await call_next(request)
        response.headers["X-Request-Id"] = request_id
        log.info("%s %s %s %d %.1fms", request_id, request.method, request.url.path, response.status_code,
                 (time.monotonic() - start) * 1000)
        return response

    def require_auth(x_api_key: str | None = Header(default=None)):
        if not valid_api_key(x_api_key, app.state.api_key):
            raise HTTPException(401, detail={"code": "unauthorized", "message": "Invalid API key"})

    def data(value, status=200):
        return Response(content=json.dumps({"data": value}), status_code=status, media_type="application/json")

    @app.exception_handler(HTTPException)
    async def http_error(request, exc):
        detail = exc.detail if isinstance(exc.detail, dict) else {"code": "internal", "message": str(exc.detail)}
        return Response(content=json.dumps({"error": detail}), status_code=exc.status_code, media_type="application/json")

    @app.exception_handler(RequestValidationError)
    async def validation_error(request, exc):
        return Response(content=json.dumps({"error": {"code": "invalid_request", "message": "Request validation failed"}}),
                         status_code=422, media_type="application/json")

    @app.get("/v1/health")
    def health():
        return {"data": {"ok": True}}

    @app.get("/v1/services", dependencies=[Depends(require_auth)])
    def services():
        status = _unit_status(["ssh", "xray", "vpn-openvpn-tcp", "vpn-openvpn-udp"])
        xray_routes, xray_reason = _xray_proxy_status(app.state.xray_front_proxy)
        service_ok = {
            "ssh": status.get("ssh") == "running" and _port_listening(22),
            "ovpn-tcp": status.get("vpn-openvpn-tcp") == "running" and _port_listening(1194),
            "ovpn-udp": status.get("vpn-openvpn-udp") == "running" and _udp_port_listening(1194),
        }
        definitions = [
            ("ssh", "SSH", service_ok["ssh"], None, 30),
            ("vmess", "VMess", "vmess" in xray_routes, xray_reason, 30),
            ("vless", "VLESS", "vless" in xray_routes, xray_reason, 30),
            ("trojan", "Trojan", "trojan" in xray_routes, xray_reason, 30),
            ("ovpn-tcp", "OpenVPN TCP", service_ok["ovpn-tcp"], None, 30),
            ("ovpn-udp", "OpenVPN UDP", service_ok["ovpn-udp"], None, 30),
        ]
        return data({"generated_at": iso_utc(int(time.time())), "services": [
            {"id": sid, "label": label, "available": available,
             "reason": reason if reason else (None if available else "service unit is not active"),
             "max_days": days, "ports": _supported_ports(sid)}
            for sid, label, available, reason, days in definitions]})

    @app.get("/v1/status", dependencies=[Depends(require_auth)])
    def status():
        now = time.monotonic()
        cached_at, cached = app.state.status_cache
        if cached is not None and now - cached_at < 5:
            return data(cached)
        units = ["ssh", "xray", "vpn-openvpn-tcp", "vpn-openvpn-udp"]
        service_status = _unit_status(units)
        counts = get_manager().registry.count_by_service()
        total, available = _memory()
        result = {"server": {"domain": app.state.domain, "uptime_seconds": _uptime(), "load1": _load1(),
                              "ram": {"used_mb": max(total - available, 0), "total_mb": total}},
                  "services": service_status,
                  "accounts": {service: counts.get(service, 0) for service in
                               ("ssh", "vmess", "vless", "trojan", "ovpn-tcp", "ovpn-udp")},
                  "online": {"ssh": _online_ssh(), "ovpn": _online_ovpn(), "xray": None}}
        app.state.status_cache = (now, result)
        return data(result)

    @app.get("/v1/accounts", dependencies=[Depends(require_auth)])
    def list_accounts(service: str | None = None, limit: int = 100, offset: int = 0):
        try: rows = get_manager().registry.list(service, limit, offset)
        except ValueError as exc: raise HTTPException(422, detail={"code": "invalid_request", "message": str(exc)})
        return data([_safe_row(row) for row in rows])

    @app.post("/v1/accounts", status_code=201, dependencies=[Depends(require_auth)])
    def create_account(body: CreateAccount, response: Response, idempotency_key: str | None = Header(default=None, alias="Idempotency-Key")):
        if (body.days is None) == (body.hours is None):
            raise HTTPException(422, detail={"code": "invalid_request", "message": "provide exactly one of days or hours"})
        if body.username:
            try: validate_username(body.username, body.service)
            except ValueError as exc: raise HTTPException(422, detail={"code": "invalid_request", "message": str(exc)})
        req_hash = hashlib.sha256(body.model_dump_json().encode()).hexdigest()
        if idempotency_key:
            saved = get_manager().registry.get_idempotency(idempotency_key)
            if saved:
                if saved["request_hash"] != req_hash:
                    raise HTTPException(409, detail={"code": "conflict", "message": "Idempotency-Key was used with a different request"})
                return data(saved["response"], 201)
        xray_routes, xray_reason = _xray_proxy_status(app.state.xray_front_proxy)
        if body.service in ("vmess", "vless", "trojan") and body.service not in xray_routes:
            raise HTTPException(503, detail={"code": "service_unavailable", "message": "Xray service is not published until a supported front proxy is configured"})
        required_unit = {"ssh": "ssh", "ovpn-tcp": "vpn-openvpn-tcp", "ovpn-udp": "vpn-openvpn-udp"}.get(body.service)
        listener_active = {"ssh": _port_listening(22), "ovpn-tcp": _port_listening(1194), "ovpn-udp": _udp_port_listening(1194)}.get(body.service, True)
        if required_unit and (_unit_status([required_unit]).get(required_unit) != "running" or not listener_active):
            raise HTTPException(503, detail={"code": "service_unavailable", "message": f"{required_unit} or its listener is unavailable"})
        try:
            result = get_manager().create(**body.model_dump())
        except (ValueError, ConflictError) as exc:
            if idempotency_key:
                for _ in range(20):
                    time.sleep(0.025)
                    saved = get_manager().registry.get_idempotency(idempotency_key)
                    if saved:
                        if saved["request_hash"] == req_hash:
                            return data(saved["response"], 201)
                        raise HTTPException(409, detail={"code": "conflict", "message": "Idempotency-Key was used with a different request"})
            raise HTTPException(409 if "exists" in str(exc) or "already" in str(exc) else 422,
                                detail={"code": "conflict" if "exists" in str(exc) or "already" in str(exc) else "invalid_request", "message": str(exc)})
        except TimeoutError as exc:
            raise HTTPException(503, detail={"code": "busy", "message": str(exc)})
        except Exception as exc:
            log.error("account create failed (%s)", type(exc).__name__)
            raise HTTPException(503, detail={"code": "service_unavailable", "message": "Account operation failed"})
        result["created_at"] = iso_utc(result["created_at"])
        result["expires_at"] = iso_utc(result["expires_at"])
        if body.service == "ssh":
            result["connection"] = {"host": app.state.domain, "password": result["meta"].get("password"),
                                    "ports": _listening_ports([22, 143, 109, 80, 443, 447, 777]),
                                    "supported_ports": _supported_ports(body.service)}
        elif body.service.startswith("ovpn-"):
            result["connection"] = {k: result["meta"].get(k) for k in ("host", "port", "proto", "filename", "content")}
            result["connection"]["supported_ports"] = _supported_ports(body.service)
        elif body.service in ("vmess", "vless", "trojan"):
            result["connection"] = _xray_connection(body.service, app.state.domain, result["meta"] | {"username": result["username"]}, xray_routes)
            result["connection"]["supported_ports"] = _supported_ports(body.service)
        result.pop("meta", None)
        if idempotency_key:
            try: get_manager().registry.save_idempotency(idempotency_key, req_hash, result)
            except ConflictError:
                saved = get_manager().registry.get_idempotency(idempotency_key)
                if saved and saved["request_hash"] == req_hash: result = saved["response"]
                else: raise HTTPException(409, detail={"code": "conflict", "message": "Idempotency-Key conflict"})
        return data(result, 201)

    @app.get("/v1/accounts/{service}/{username}", dependencies=[Depends(require_auth)])
    def get_account(service: str, username: str):
        row = get_manager().registry.get(service, username)
        if not row: raise HTTPException(404, detail={"code": "not_found", "message": "Account not found"})
        return data(_safe_row(row))

    @app.post("/v1/accounts/{service}/{username}/renew", dependencies=[Depends(require_auth)])
    def renew_account(service: str, username: str, body: RenewAccount):
        try: row = get_manager().renew(service, username, body.days)
        except NotImplementedError as exc: raise HTTPException(501, detail={"code": "not_supported", "message": str(exc)})
        except ValueError as exc: raise HTTPException(422, detail={"code": "invalid_request", "message": str(exc)})
        except Exception as exc:
            log.error("account delete failed (%s)", type(exc).__name__)
            raise HTTPException(503, detail={"code": "service_unavailable", "message": "Account operation failed"})
        if row is None: raise HTTPException(404, detail={"code": "not_found", "message": "Account not found"})
        return data(_safe_row(row))

    @app.delete("/v1/accounts/{service}/{username}", dependencies=[Depends(require_auth)])
    def delete_account(service: str, username: str):
        try: removed = get_manager().delete(service, username)
        except TimeoutError as exc: raise HTTPException(503, detail={"code": "busy", "message": str(exc)})
        except ValueError as exc: raise HTTPException(422, detail={"code": "invalid_request", "message": str(exc)})
        except Exception: raise HTTPException(503, detail={"code": "service_unavailable", "message": "Account operation failed"})
        if not removed: raise HTTPException(404, detail={"code": "not_found", "message": "Account not found"})
        return data({"deleted": True, "service": service, "username": username})

    return app


def _safe_row(row):
    return {key: (iso_utc(row[key]) if key in ("created_at", "expires_at") else row[key])
            for key in ("id", "service", "username", "created_at", "expires_at", "max_sessions", "status")}


def _unit_status(units):
    import subprocess
    result = subprocess.run(["systemctl", "is-active", *units], text=True, capture_output=True)
    lines = result.stdout.splitlines()
    return {name: "running" if i < len(lines) and lines[i] == "active" else "stopped" for i, name in enumerate(units)}


def _memory():
    total = available = 0
    try:
        with open("/proc/meminfo") as stream:
            for line in stream:
                if line.startswith("MemTotal:"): total = int(line.split()[1]) // 1024
                elif line.startswith("MemAvailable:"): available = int(line.split()[1]) // 1024
    except OSError: pass
    return total, available


def _uptime():
    try:
        with open("/proc/uptime") as stream: return int(float(stream.read().split()[0]))
    except (OSError, ValueError, IndexError): return 0


def _load1():
    try:
        with open("/proc/loadavg") as stream: return float(stream.read().split()[0])
    except (OSError, ValueError, IndexError): return 0.0


def _listening_ports(candidates):
    import socket
    try:
        with open("/proc/net/tcp") as stream: rows = stream.readlines()[1:]
        with open("/proc/net/tcp6") as stream: rows += stream.readlines()[1:]
        active = {int(row.split()[1].split(":")[1], 16) for row in rows if row.split()[3] == "0A"}
        return {str(port): port in active for port in candidates if port in active}
    except OSError: return {}


def _online_ssh():
    import re
    import subprocess
    try:
        output = subprocess.run(["ps", "-eo", "args="], text=True, capture_output=True, check=False).stdout
        return sum(1 for line in output.splitlines() if re.search(r"sshd:\s+[a-z][a-z0-9_]{2,19}@", line))
    except OSError: return None


def _online_ovpn():
    try:
        from vpnctl.guard import openvpn_sessions
        return len(openvpn_sessions())
    except OSError: return None


def _xray_proxy_status(enabled):
    if not enabled:
        return {}, "front proxy for Xray websocket is not configured"
    import subprocess
    try:
        config = subprocess.run(["nginx", "-T"], text=True, capture_output=True, check=False).stdout
    except OSError:
        return {}, "nginx is unavailable"
    ports = {}
    listen80 = bool(__import__("re").search(r"listen\s+80(?:\s|;)", config)) and _port_listening(80)
    listen443 = bool(__import__("re").search(r"listen\s+443\s+ssl", config)) and _port_listening(443)
    for service, port in (("vmess", 10001), ("vless", 10002), ("trojan", 10003)):
        path = {"vmess": "/vmess", "vless": "/vless", "trojan": "/trojan-ws"}[service]
        if f"127.0.0.1:{port}" in config and path in config and _port_listening(port):
            routes = {"ws_none_tls": listen80, "ws_tls": listen443}
            if any(routes.values()): ports[service] = routes
    unit_status = _unit_status(["nginx", "xray"])
    if unit_status.get("nginx") != "running" or unit_status.get("xray") != "running":
        return {}, "nginx or Xray service is not active"
    return ports, None if ports else "nginx websocket route or Xray inbound is not active"


def _port_listening(port):
    return bool(_listening_ports([port]).get(str(port), False))


def _udp_port_listening(port):
    try:
        with open("/proc/net/udp") as stream: rows = stream.readlines()[1:]
        with open("/proc/net/udp6") as stream: rows += stream.readlines()[1:]
        return any(int(row.split()[1].split(":")[1], 16) == port for row in rows if len(row.split()) > 1)
    except OSError: return False


def _xray_connection(service, host, meta, routes):
    import base64
    import json
    from urllib.parse import quote
    route = routes.get(service, {})
    ident = meta.get("uuid") or meta.get("password")
    links = {}
    if route.get("ws_tls"):
        if service == "vmess":
            payload = {"v": "2", "ps": meta.get("username", "vpn"), "add": host, "port": "443", "id": ident,
                       "aid": "0", "net": "ws", "path": {"vmess": "/vmess", "vless": "/vless", "trojan": "/trojan-ws"}[service], "type": "none", "host": host, "tls": "tls", "sni": host}
            links["ws_tls"] = "vmess://" + base64.b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode()
        elif service == "vless":
            links["ws_tls"] = f"vless://{ident}@{host}:443?path=%2Fvless&security=tls&host={quote(host)}&type=ws&sni={quote(host)}"
        else:
            links["ws_tls"] = f"trojan://{ident}@{host}:443?path=%2Ftrojan-ws&security=tls&host={quote(host)}&type=ws&sni={quote(host)}"
    if route.get("ws_none_tls"):
        if service == "vmess":
            payload = {"v": "2", "ps": meta.get("username", "vpn"), "add": host, "port": "80", "id": ident,
                       "aid": "0", "net": "ws", "path": {"vmess": "/vmess", "vless": "/vless", "trojan": "/trojan-ws"}[service], "type": "none", "host": host, "tls": "none"}
            links["ws_none_tls"] = "vmess://" + base64.b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode()
        elif service == "vless":
            links["ws_none_tls"] = f"vless://{ident}@{host}:80?path=%2Fvless&security=none&host={quote(host)}&type=ws"
        else:
            links["ws_none_tls"] = f"trojan://{ident}@{host}:80?path=%2Ftrojan-ws&security=none&host={quote(host)}&type=ws"
    return {"host": host, ("password" if service == "trojan" else "uuid"): ident, "links": links}


app = create_app()
