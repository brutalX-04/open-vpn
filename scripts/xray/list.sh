#!/bin/bash
# ============================================================
#  xray/list.sh — Daftar Semua Akun Xray
# ============================================================
source /etc/vpn/lib/colors.sh
require_root

XRAY_CONFIG="/etc/xray/config.json"

clear
header "  DAFTAR AKUN XRAY  "
echo ""

# ── Baca menggunakan Python3 + JSON parsing yang proper ────
python3 - <<PYEOF
import json, sys, os
from datetime import datetime

config_file = "${XRAY_CONFIG}"
RED   = '\033[1;31m'
GREEN = '\033[1;32m'
CYAN  = '\033[0;36m'
YELLOW= '\033[1;33m'
WHITE = '\033[1;37m'
NC    = '\033[0m'

try:
    with open(config_file, 'r') as f:
        config = json.load(f)
except Exception as e:
    print(f"  {RED}Gagal baca config: {e}{NC}")
    sys.exit(1)

today = datetime.now().date()
inbounds = config.get('inbounds', [])

protocols = {}
for inbound in inbounds:
    proto = inbound.get('protocol', 'unknown')
    tag   = inbound.get('tag', proto)
    clients = inbound.get('settings', {}).get('clients', [])
    for c in clients:
        email = c.get('email', 'unknown')
        comment = c.get('comment', '')
        # Extract expiry dari comment: "username YYYY-MM-DD"
        exp_str = 'N/A'
        status = f"{GREEN}AKTIF{NC}"
        if comment:
            parts = comment.split(' ')
            if len(parts) >= 2:
                try:
                    exp_date = datetime.strptime(parts[-1], '%Y-%m-%d').date()
                    exp_str = exp_date.strftime('%d-%m-%Y')
                    if exp_date < today:
                        status = f"{RED}EXPIRED{NC}"
                    elif (exp_date - today).days <= 3:
                        status = f"{YELLOW}SEGERA HABIS{NC}"
                except:
                    pass
        if email not in protocols:
            protocols[email] = {'protos': [], 'exp': exp_str, 'status': status}
        protocols[email]['protos'].append(tag)

if not protocols:
    print(f"  {YELLOW}Tidak ada akun Xray.{NC}")
    sys.exit(0)

print(f"  {WHITE}{'USERNAME':<20} {'EXPIRED':<14} {'STATUS':<18} {'PROTOKOL'}{NC}")
print(f"  {'─'*70}")

for email, info in sorted(protocols.items()):
    protos = ', '.join(sorted(set(info['protos'])))
    print(f"  {email:<20} {info['exp']:<14} {info['status']:<27} {CYAN}{protos}{NC}")

print(f"\n  {WHITE}Total{NC}: {GREEN}{len(protocols)} akun{NC}")
PYEOF

echo ""
press_any_key
menu-xray
