#!/bin/bash
set -euo pipefail

HOST="${1:-}"
if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
fi
if [[ ! "${HOST}" =~ ^[A-Za-z0-9.-]+$ || "${HOST}" != *.* ]]; then
    echo "Usage: $0 <public-domain>" >&2
    exit 2
fi

PUBLIC_IP=$(curl -4fsS --max-time 10 https://api.ipify.org)
DNS_IP=$(getent ahostsv4 "${HOST}" | awk 'NR == 1 {print $1}')
if [[ -z "${DNS_IP}" || "${DNS_IP}" != "${PUBLIC_IP}" ]]; then
    echo "DNS A record for ${HOST} must resolve to this VM's public IPv4 (${PUBLIC_IP})." >&2
    exit 1
fi

if command -v iptables >/dev/null 2>&1 && ! iptables -C INPUT -p tcp -m multiport --dports 80,443 -m state --state NEW -j ACCEPT 2>/dev/null; then
    REJECT_RULE=$(iptables -L INPUT --line-numbers -n | awk '/REJECT/ {print $1; exit}')
    if [[ -n "${REJECT_RULE}" ]]; then
        iptables -I INPUT "${REJECT_RULE}" -p tcp -m multiport --dports 80,443 -m state --state NEW -j ACCEPT
    else
        iptables -I INPUT 1 -p tcp -m multiport --dports 80,443 -m state --state NEW -j ACCEPT
    fi
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
    fi
fi

apt-get update -y
apt-get install -y certbot nginx

# HTTP Custom SSH-over-WebSocket is proxied by Nginx to this loopback bridge.
bash "$(dirname "${BASH_SOURCE[0]}")/enable-ssh-ws.sh"

mkdir -p /var/www/html/.well-known/acme-challenge /etc/nginx/sites-available /etc/nginx/sites-enabled
# Nginx must be able to traverse every webroot directory and read Certbot's
# token files. Existing webroot permissions may have been tightened by another
# service, which otherwise makes the ACME URL return 403.
chmod 755 /var/www/html /var/www/html/.well-known /var/www/html/.well-known/acme-challenge
mkdir -p /etc/nginx/conf.d
cat >/etc/nginx/conf.d/vpn-api-rate.conf <<'EOF'
limit_req_zone $binary_remote_addr zone=vpn_api:10m rate=10r/s;
EOF
SITE=/etc/nginx/sites-available/vpn-xray
cat >"${SITE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${HOST};
    location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 404; }
}
EOF
ln -sfn "${SITE}" /etc/nginx/sites-enabled/vpn-xray
nginx -t
systemctl reload nginx

# Check the exact Host header and challenge location locally before asking the
# CA to validate it. This catches Nginx vhost conflicts and webroot permission
# errors with a useful message instead of an opaque ACME unauthorized error.
PROBE_TOKEN="vpn-acme-probe-$(date +%s)-$$"
PROBE_FILE="/var/www/html/.well-known/acme-challenge/${PROBE_TOKEN}"
printf '%s' "${PROBE_TOKEN}" >"${PROBE_FILE}"
chmod 644 "${PROBE_FILE}"
PROBE_BODY=$(curl --noproxy '*' -fsS --max-time 5 --resolve "${HOST}:80:127.0.0.1" \
    "http://${HOST}/.well-known/acme-challenge/${PROBE_TOKEN}" 2>/dev/null || true)
rm -f "${PROBE_FILE}"
if [[ "${PROBE_BODY}" != "${PROBE_TOKEN}" ]]; then
    echo "Nginx cannot serve the ACME webroot locally for ${HOST}. Check for another port-80 virtual host or access restrictions." >&2
    exit 1
fi

if ! certbot certonly --webroot -w /var/www/html -d "${HOST}" --non-interactive \
    --agree-tos --register-unsafely-without-email --keep-until-expiring
then
    echo "Let's Encrypt could not fetch the challenge for ${HOST}. Confirm its DNS A/AAAA records point to this VPS, TCP port 80 is reachable in the cloud firewall, and any CDN/proxy allows /.well-known/acme-challenge/." >&2
    exit 1
fi

# Refresh the Stunnel certificate and ensure Dropbear/Stunnel listeners are
# configured after the domain certificate has been issued.
bash "$(dirname "${BASH_SOURCE[0]}")/configure-ssh-transports.sh"

# The installer may have enabled a separate API vhost on this same hostname.
# The combined TLS vhost below serves both Xray and API paths, so disable the
# duplicate site when it targets this exact host. Do this only after the
# certificate is available, so a failed issuance leaves the old API vhost up.
API_LINK=/etc/nginx/sites-enabled/vpn-api
if [[ -L "${API_LINK}" ]]; then
    API_TARGET=$(readlink -f "${API_LINK}" || true)
    if [[ -n "${API_TARGET}" ]] && grep -Fq "server_name ${HOST};" "${API_TARGET}"; then
        rm -f "${API_LINK}"
    fi
fi

cat >"${SITE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${HOST};
    location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
    location / {
        if (\$http_upgrade !~* "websocket") { return 301 https://\$host\$request_uri; }
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 360s;
        proxy_buffering off;
        limit_req zone=vpn_api burst=20 nodelay;
        proxy_pass http://127.0.0.1:2222;
    }
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${HOST};
    ssl_certificate /etc/letsencrypt/live/${HOST}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${HOST}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 16k;
    location ^~ /v1/ {
        limit_req zone=vpn_api burst=10 nodelay;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:8088;
    }
    location = /vmess {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 360s;
        proxy_pass http://127.0.0.1:10001;
    }
    location = /vless {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 360s;
        proxy_pass http://127.0.0.1:10002;
    }
    location = /trojan-ws {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 360s;
        proxy_pass http://127.0.0.1:10003;
    }
    # Default root route carries SSH over WebSocket; Xray paths above remain separate.
    location / {
        if (\$http_upgrade !~* "websocket") { return 404; }
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 360s;
        proxy_buffering off;
        limit_req zone=vpn_api burst=20 nodelay;
        proxy_pass http://127.0.0.1:2222;
    }
}
EOF
nginx -t
systemctl reload nginx

python3 - "${HOST}" <<'PY'
import os
import sys
import tempfile

host = sys.argv[1]

def update(path, values, mode=None):
    try:
        with open(path, encoding="utf-8") as stream:
            lines = stream.readlines()
    except FileNotFoundError:
        lines = []
    seen = set()
    output = []
    for line in lines:
        key = line.partition("=")[0].strip()
        if key in values:
            if key not in seen:
                output.append(f"{key}={values[key]}\n")
                seen.add(key)
        else:
            output.append(line if line.endswith("\n") else line + "\n")
    for key, value in values.items():
        if key not in seen:
            output.append(f"{key}={value}\n")
    directory = os.path.dirname(path)
    fd, temporary = tempfile.mkstemp(prefix=".xray-proxy-", dir=directory, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.writelines(output)
            stream.flush()
            os.fsync(stream.fileno())
        if mode is not None:
            os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

update("/etc/vpn/config.conf", {"DOMAIN": host})
update("/etc/vpn/api.env", {"DOMAIN": host, "XRAY_FRONT_PROXY": "1"}, 0o600)
PY

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/vpn-xray-reload-nginx <<'HOOK'
#!/bin/sh
systemctl reload nginx
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/vpn-xray-reload-nginx
systemctl restart vpn-api.service

HTTP_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' "https://${HOST}/")
if [[ "${HTTP_STATUS}" != "404" ]]; then
    echo "HTTPS validation returned HTTP ${HTTP_STATUS}, expected 404 on the private root path." >&2
    exit 1
fi

echo "Xray and SSH WebSocket proxies are active for ${HOST} on HTTPS; plain SSH WebSocket is available on port 80. API /v1/ remains bound to localhost on port 8088."
