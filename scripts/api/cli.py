#!/usr/bin/env python3
# ============================================================
#  api/cli.py — JSON API CLI interface for Telegram Bot Integration
# ============================================================

import sys
import os
import json
import argparse
import subprocess
import random
import string
from datetime import datetime, timedelta

XRAY_CONFIG = "/etc/xray/config.json"
VPN_CONF = "/etc/vpn/config.conf"
OVPN_DIR = "/etc/openvpn"
CLIENT_DIR = "/etc/openvpn/clients"
CA_DIR = "/etc/openvpn/easy-rsa"

def get_config():
    conf = {}
    if os.path.exists(VPN_CONF):
        with open(VPN_CONF, 'r') as f:
            for line in f:
                if '=' in line and not line.startswith('#'):
                    k, v = line.strip().split('=', 1)
                    conf[k] = v.strip()
    return conf

def run_cmd(cmd):
    try:
        res = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        return res.returncode == 0, res.stdout.strip(), res.stderr.strip()
    except Exception as e:
        return False, "", str(e)

def get_status():
    config = get_config()
    mem_total = 0
    mem_avail = 0
    if os.path.exists('/proc/meminfo'):
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                if 'MemTotal:' in line:
                    mem_total = int(line.split()[1]) // 1024
                elif 'MemAvailable:' in line:
                    mem_avail = int(line.split()[1]) // 1024
    mem_used = mem_total - mem_avail

    services = ['ssh', 'dropbear', 'stunnel4', 'nginx', 'xray', 'openvpn@server-tcp', 'openvpn@server-udp']
    svc_status = {}
    for s in services:
        ok, out, _ = run_cmd(f"systemctl is-active {s}")
        svc_status[s] = "running" if out == "active" else "stopped"

    _, ssh_users, _ = run_cmd("awk -F: '$3 >= 1000 && $1 != \"nobody\" {c++} END {print c+0}' /etc/passwd")
    
    xray_users = 0
    if os.path.exists(XRAY_CONFIG):
        with open(XRAY_CONFIG, 'r') as f:
            content = f.read()
            xray_users = content.count('"email"')

    uptime = subprocess.getoutput("uptime -p").replace("up ", "")

    return {
        "status": "success",
        "data": {
            "ip": config.get("IP", "N/A"),
            "domain": config.get("DOMAIN", "N/A"),
            "uptime": uptime,
            "ram": {"used_mb": mem_used, "total_mb": mem_total},
            "services": svc_status,
            "user_counts": {
                "ssh": int(ssh_users or 0),
                "xray": xray_users
            }
        }
    }

def create_user(proto, username, days=None, hours=None, password=None):
    if not username:
        return {"status": "error", "message": "Username is required"}

    config = get_config()
    domain = config.get("DOMAIN", "localhost")
    ip = config.get("IP", "127.0.0.1")

    now = datetime.now()
    if hours:
        exp_dt = now + timedelta(hours=hours)
    elif days:
        exp_dt = now + timedelta(days=days)
    else:
        exp_dt = now + timedelta(days=30)

    exp_date = exp_dt.strftime("%Y-%m-%d")
    exp_display = exp_dt.strftime("%Y-%m-%d %H:%M:%S")

    # SSH
    if proto == 'ssh':
        if not password:
            password = ''.join(random.choices(string.ascii_letters + string.digits, k=8))
        
        ok, out, err = run_cmd(f"useradd -e '{exp_date}' -s /bin/false -M '{username}' && echo '{password}\\n{password}' | passwd '{username}'")
        if not ok:
            return {"status": "error", "message": f"Failed creating SSH user: {err}"}
        return {
            "status": "success",
            "data": {
                "username": username,
                "password": password,
                "expired": exp_display,
                "domain": domain,
                "ip": ip,
                "ports": {
                    "ssh": config.get("PORT_SSH", "22"),
                    "dropbear": config.get("PORT_DROPBEAR", "143,109"),
                    "ws": config.get("PORT_SSHWS", "80"),
                    "ssl_ws": config.get("PORT_SSLWS", "443"),
                    "stunnel": config.get("PORT_STUNNEL", "447,777"),
                    "udpgw": "7100-7300"
                }
            }
        }

    # Xray (Vmess / Vless / Trojan)
    elif proto in ['vmess', 'vless', 'trojan']:
        import uuid, base64
        u_id = str(uuid.uuid4())
        
        if os.path.exists(XRAY_CONFIG):
            with open(XRAY_CONFIG, 'r') as f:
                x_cfg = json.load(f)

            for inbound in x_cfg.get('inbounds', []):
                tag = inbound.get('tag', '')
                clients = inbound.get('settings', {}).get('clients', [])
                if proto in tag:
                    entry = {"id": u_id, "email": username, "comment": f"{username} {exp_display}"}
                    if proto == 'trojan':
                        entry = {"password": u_id, "email": username, "comment": f"{username} {exp_display}"}
                    elif proto == 'vless':
                        entry = {"id": u_id, "flow": "", "email": username, "comment": f"{username} {exp_display}"}
                    clients.append(entry)

            with open(XRAY_CONFIG, 'w') as f:
                json.dump(x_cfg, f, indent=2)

            run_cmd("systemctl restart xray")

        links = {}
        if proto == 'vmess':
            v_tls = base64.b64encode(json.dumps({"v":"2","ps":username,"add":domain,"port":"443","id":u_id,"aid":"0","net":"ws","path":"/vmess","type":"none","host":domain,"tls":"tls","sni":domain}).encode()).decode()
            v_ntls = base64.b64encode(json.dumps({"v":"2","ps":username,"add":domain,"port":"80","id":u_id,"aid":"0","net":"ws","path":"/vmess","type":"none","host":domain,"tls":"none"}).encode()).decode()
            v_grpc = base64.b64encode(json.dumps({"v":"2","ps":username,"add":domain,"port":"443","id":u_id,"aid":"0","net":"grpc","path":"vmess-grpc","type":"none","host":domain,"tls":"tls","sni":domain}).encode()).decode()
            links = {"ws_tls": f"vmess://{v_tls}", "ws_none_tls": f"vmess://{v_ntls}", "grpc": f"vmess://{v_grpc}"}
        elif proto == 'vless':
            links = {
                "ws_tls": f"vless://{u_id}@{domain}:443?path=%2Fvless&security=tls&host={domain}&type=ws&sni={domain}#{username}",
                "ws_none_tls": f"vless://{u_id}@{domain}:80?path=%2Fvless&security=none&host={domain}&type=ws#{username}",
                "grpc": f"vless://{u_id}@{domain}:443?mode=gun&security=tls&type=grpc&serviceName=vless-grpc&sni={domain}#{username}"
            }
        elif proto == 'trojan':
            links = {
                "ws_tls": f"trojan://{u_id}@{domain}:443?path=%2Ftrojan-ws&security=tls&host={domain}&type=ws&sni={domain}#{username}",
                "ws_none_tls": f"trojan://{u_id}@{domain}:80?path=%2Ftrojan-ws&security=none&host={domain}&type=ws#{username}",
                "grpc": f"trojan://{u_id}@{domain}:443?mode=gun&security=tls&type=grpc&serviceName=trojan-grpc&sni={domain}#{username}"
            }

        return {
            "status": "success",
            "data": {
                "username": username,
                "uuid": u_id,
                "protocol": proto,
                "expired": exp_display,
                "links": links
            }
        }

    # OpenVPN TCP / UDP
    elif proto in ['ovpn-tcp', 'ovpn-udp']:
        sub_proto = "tcp" if proto == "ovpn-tcp" else "udp"
        port_val = config.get(f"PORT_OVPN_{sub_proto.upper()}", "1194")
        
        os.makedirs(CLIENT_DIR, exist_ok=True)
        ovpn_file = os.path.join(CLIENT_DIR, f"{username}-{sub_proto}.ovpn")
        
        ovpn_content = f"""client
dev tun
proto {sub_proto}
remote {domain} {port_val}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
cipher AES-256-CBC
compress lz4-v2
key-direction 1
verb 3

# Expired: {exp_display}
"""
        with open(ovpn_file, 'w') as f:
            f.write(ovpn_content)

        return {
            "status": "success",
            "data": {
                "username": username,
                "protocol": f"OpenVPN {sub_proto.upper()}",
                "port": port_val,
                "expired": exp_display,
                "file_path": ovpn_file,
                "content": ovpn_content
            }
        }

    return {"status": "error", "message": f"Unsupported protocol: {proto}"}

def create_trial_bundle(username, hours=3):
    """Creates ALL account types (SSH, Vmess, Vless, Trojan, OVPN TCP & UDP) with N hours duration!"""
    results = {}
    protos = ['ssh', 'vmess', 'vless', 'trojan', 'ovpn-tcp', 'ovpn-udp']
    for p in protos:
        uname = f"{username}-{p}" if p != 'ssh' else username
        res = create_user(proto=p, username=uname, hours=hours, password=f"tr{random.randint(100,999)}")
        if res.get("status") == "success":
            results[p] = res.get("data")

    return {
        "status": "success",
        "trial_username": username,
        "hours": hours,
        "accounts": results
    }

def main():
    parser = argparse.ArgumentParser(description="VPN API CLI for Bot Integration")
    parser.add_argument("action", choices=["status", "create", "delete", "renew", "list", "trial"])
    parser.add_argument("--type", help="Protocol/Type (ssh, vmess, vless, trojan, ovpn-tcp, ovpn-udp)")
    parser.add_argument("--user", help="Username")
    parser.add_argument("--pass", dest="password", help="Password (for SSH)")
    parser.add_argument("--days", type=int, help="Active days")
    parser.add_argument("--hours", type=int, help="Active hours (e.g. 3 for trial)")

    args = parser.parse_args()

    if args.action == "status":
        res = get_status()
    elif args.action == "create":
        res = create_user(args.type, args.user, args.days, args.hours, args.password)
    elif args.action == "trial":
        uname = args.user or f"tr{random.randint(1000,9999)}"
        hours = args.hours or 3
        res = create_trial_bundle(uname, hours=hours)
    else:
        res = {"status": "error", "message": "Action not supported"}

    print(json.dumps(res, indent=2))

if __name__ == "__main__":
    main()
