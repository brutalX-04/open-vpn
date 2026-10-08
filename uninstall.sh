#!/usr/bin/env bash
set -Eeuo pipefail

PURGE_DATA=0
PURGE_PACKAGES=0
REMOVE_FIREWALL=0
ASSUME_YES=0

usage() {
    cat <<'EOF'
Usage: sudo bash uninstall.sh [--purge-data] [--purge-packages] [--remove-firewall] [--yes]

  --purge-data  Also delete managed VPN accounts and remove VPN configs,
                registry database, PKI, and logs. This cannot be undone.
  --purge-packages  Also purge the dedicated OpenVPN, Easy-RSA, Dropbear,
                    and Stunnel packages (does not run autoremove).
  --remove-firewall Remove matching OpenVPN 1194 and VPN NAT rules. Exact
                    matching rules that existed before installation may also be removed.
  --yes         Skip the confirmation prompt (use with care).
EOF
}

while (($#)); do
    case "$1" in
        --purge-data) PURGE_DATA=1 ;;
        --purge-packages) PURGE_PACKAGES=1 ;;
        --remove-firewall) REMOVE_FIREWALL=1 ;;
        --yes) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ ${EUID} -ne 0 ]]; then
    echo "Run this script as root: sudo bash uninstall.sh" >&2
    exit 1
fi

cat <<EOF
This will remove the VPN installer services, their systemd units, CLI links,
and Nginx sites. Shared system services (SSH, cron, Nginx, and fail2ban),
unrelated Nginx sites, and Let's Encrypt certificates will be kept. Packages
are retained unless --purge-packages is specified.
EOF
if [[ ${PURGE_DATA} -eq 1 ]]; then
    cat <<'EOF'
--purge-data is enabled: managed accounts will be deleted through their
drivers, then /etc/vpn, /var/lib/vpn, /var/log/vpn, /etc/openvpn, and
/etc/xray will be removed, including account records, credentials, and PKI.
EOF
fi
if [[ ${PURGE_PACKAGES} -eq 1 ]]; then
    echo "--purge-packages will remove openvpn, easy-rsa, dropbear, and stunnel4 packages."
fi
if [[ ${REMOVE_FIREWALL} -eq 1 ]]; then
    echo "--remove-firewall will remove matching 1194 and VPN NAT rules, including any identical rules that predated installation."
fi

if [[ ${ASSUME_YES} -ne 1 ]]; then
    read -r -p 'Continue? Type uninstall to confirm: ' CONFIRM
    if [[ ${CONFIRM} != uninstall ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

UNITS=(
    vpn-api.service
    vpn-session-guard.service
    vpn-openvpn-tcp.service
    vpn-openvpn-udp.service
    vpn-expiry-cleanup.timer
    vpn-expiry-cleanup.service
    vpn-crl-refresh.timer
    vpn-crl-refresh.service
    badvpn-7100.service
    badvpn-7200.service
    badvpn-7300.service
)

# Stop recurring work and API/guard processes first. Keep OpenVPN and Xray
# online until managed accounts have been deleted when --purge-data is used.
systemctl disable --now vpn-expiry-cleanup.timer vpn-crl-refresh.timer \
    vpn-api.service vpn-session-guard.service >/dev/null 2>&1 || true

REGISTRY_DB=/var/lib/vpn/accounts.db
if [[ -r /etc/vpn/api.env ]]; then
    CONFIGURED_DB=$(sed -n 's/^REGISTRY_DB=//p' /etc/vpn/api.env | head -n 1)
    if [[ -n ${CONFIGURED_DB} ]]; then
        REGISTRY_DB=${CONFIGURED_DB%\"}
        REGISTRY_DB=${REGISTRY_DB#\"}
        REGISTRY_DB=${REGISTRY_DB%\'}
        REGISTRY_DB=${REGISTRY_DB#\'}
    fi
fi

if [[ ${PURGE_DATA} -eq 1 && -f ${REGISTRY_DB} ]]; then
    if [[ ! -x /etc/vpn/venv/bin/python || ! -d /etc/vpn/vpnctl ]]; then
        echo "Cannot safely delete managed accounts: the installed vpnctl runtime is missing." >&2
        exit 1
    fi
    echo "Deleting accounts recorded in ${REGISTRY_DB} through the VPN drivers..."
    PYTHONPATH=/etc/vpn VPN_REGISTRY_DB="${REGISTRY_DB}" /etc/vpn/venv/bin/python - <<'PY'
from vpnctl.accounts import AccountManager
from vpnctl.registry import Registry

registry = Registry()
manager = AccountManager(registry)
deleted = 0
while True:
    rows = registry.list(limit=1000, offset=0)
    if not rows:
        break
    for row in rows:
        manager.delete(row["service"], row["username"])
        deleted += 1
print(f"Deleted {deleted} managed account records.")
PY
fi

# These daemons are dedicated tunnel services enabled by install.sh. Do not
# stop SSH or cron: doing so can lock out the VPS or affect unrelated jobs.
systemctl disable --now dropbear.service stunnel4.service >/dev/null 2>&1 || true
systemctl disable --now "${UNITS[@]}" xray.service >/dev/null 2>&1 || true

for unit in "${UNITS[@]}"; do
    rm -f "/etc/systemd/system/${unit}"
done
rm -f /etc/systemd/system/xray.service.d/20-vpn-config.conf
rmdir /etc/systemd/system/xray.service.d 2>/dev/null || true

# Remove the Xray unit and binary only when it is the /usr/local Xray service
# installed by the Xray installer used by install.sh.
if [[ -f /etc/systemd/system/xray.service ]] && grep -Eq 'ExecStart=.*(/usr/local/bin/xray|xray run)' /etc/systemd/system/xray.service; then
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
    rm -f /usr/local/bin/xray
fi

systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true

remove_link_if_target() {
    local link="$1" target="$2"
    if [[ -L ${link} && $(readlink "${link}") == "${target}" ]]; then
        rm -f -- "${link}"
    fi
}

remove_link_if_target /usr/bin/menu /etc/vpn/scripts/menu/main.sh
remove_link_if_target /usr/bin/menu-ssh /etc/vpn/scripts/menu/menu-ssh.sh
remove_link_if_target /usr/bin/menu-xray /etc/vpn/scripts/menu/menu-xray.sh
remove_link_if_target /usr/bin/menu-ovpn /etc/vpn/scripts/menu/menu-ovpn.sh
remove_link_if_target /usr/bin/running /etc/vpn/scripts/system/status.sh
remove_link_if_target /usr/bin/status /etc/vpn/scripts/system/status.sh
remove_link_if_target /usr/bin/restart-service /etc/vpn/scripts/system/restart.sh
remove_link_if_target /usr/bin/vpn-cli /usr/local/bin/vpn-cli

if [[ -f /usr/local/bin/vpn-cli ]] && grep -Fq 'vpnctl.cli' /usr/local/bin/vpn-cli; then
    rm -f /usr/local/bin/vpn-cli
fi
rm -f /usr/bin/badvpn-udpgw

# Remove only this project's Nginx sites, rate-limit include, and renewal hooks.
rm -f /etc/nginx/sites-enabled/vpn-api /etc/nginx/sites-enabled/vpn-xray
rm -f /etc/nginx/sites-available/vpn-api /etc/nginx/sites-available/vpn-xray
if [[ -f /etc/nginx/conf.d/vpn-api-rate.conf ]] && grep -Fq 'zone=vpn_api:10m rate=10r/s' /etc/nginx/conf.d/vpn-api-rate.conf; then
    rm -f /etc/nginx/conf.d/vpn-api-rate.conf
fi
rm -f /etc/letsencrypt/renewal-hooks/deploy/vpn-api-reload-nginx
rm -f /etc/letsencrypt/renewal-hooks/deploy/vpn-xray-reload-nginx
rmdir /var/www/html/.well-known/acme-challenge 2>/dev/null || true
rmdir /var/www/html/.well-known 2>/dev/null || true

if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    if nginx -t; then
        systemctl reload nginx
    else
        echo "Nginx validation failed after removing VPN sites; inspect its configuration before reloading." >&2
    fi
fi

# Remove the OpenVPN-specific NAT and listener rules. Keep shared HTTP/HTTPS
# firewall rules because this VPS may host unrelated websites or proxies.
if [[ ${REMOVE_FIREWALL} -eq 1 ]] && command -v iptables >/dev/null 2>&1; then
    NIC=$(ip -o -4 route show to default 2>/dev/null | awk 'NR == 1 {print $5}')
    if [[ -n ${NIC} ]]; then
        for subnet in 10.8.0.0/24 10.9.0.0/24; do
            while iptables -t nat -C POSTROUTING -s "${subnet}" -o "${NIC}" -j MASQUERADE 2>/dev/null; do
                iptables -t nat -D POSTROUTING -s "${subnet}" -o "${NIC}" -j MASQUERADE
            done
        done
    fi
    for protocol in tcp udp; do
        while iptables -C INPUT -p "${protocol}" --dport 1194 -m state --state NEW -j ACCEPT 2>/dev/null; do
            iptables -D INPUT -p "${protocol}" --dport 1194 -m state --state NEW -j ACCEPT
        done
    done
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi
fi

# Do not turn off IP forwarding globally: other VPNs, containers, or routes
# may rely on it. Remove only the config file created by this installer.
rm -f /etc/sysctl.d/99-openvpn.conf

if [[ ${PURGE_DATA} -eq 1 ]]; then
    rm -rf /etc/vpn /var/lib/vpn /var/log/vpn /etc/openvpn /etc/xray /usr/local/etc/xray /usr/local/share/xray
    if [[ ${REGISTRY_DB} != /var/lib/vpn/accounts.db ]]; then
        rm -f -- "${REGISTRY_DB}" "${REGISTRY_DB}-wal" "${REGISTRY_DB}-shm"
    fi
fi

if [[ ${PURGE_PACKAGES} -eq 1 ]] && command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y openvpn easy-rsa dropbear stunnel4
fi

echo "VPN installer services and project-specific Nginx configuration have been removed."
if [[ ${PURGE_DATA} -ne 1 ]]; then
    echo "VPN configuration, registry, PKI, and logs were preserved. To remove them, rerun with --purge-data."
fi
echo "Shared packages and services (SSH, cron, Nginx, fail2ban, Python, and firewall tools) were retained."
if [[ ${REMOVE_FIREWALL} -ne 1 ]]; then
    echo "Firewall rules were preserved because this installer did not record which matching rules it added. Use --remove-firewall to remove the matching VPN rules explicitly."
fi
