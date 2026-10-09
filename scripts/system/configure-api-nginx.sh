#!/bin/bash
set -euo pipefail

HOST="${1:-}"
EMAIL="${2:-}"
if [[ ! "${HOST}" =~ ^[A-Za-z0-9.-]+$ || ! "${EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo "Invalid public API hostname or email." >&2
    exit 2
fi

PUBLIC_IP=$(curl -4fsS --max-time 10 https://api.ipify.org)
DNS_IP=$(getent ahostsv4 "${HOST}" | awk 'NR == 1 {print $1}')
if [[ -z "${DNS_IP}" || "${DNS_IP}" != "${PUBLIC_IP}" ]]; then
    echo "DNS A record for ${HOST} must point directly to this VPS (${PUBLIC_IP}); found ${DNS_IP:-no IPv4 address}." >&2
    exit 1
fi
DNS_IPV6=$(getent ahostsv6 "${HOST}" | awk '{print $1}' | sort -u)
if [[ -n "${DNS_IPV6}" ]]; then
    PUBLIC_IPV6=$(curl -6fsS --max-time 10 https://api64.ipify.org 2>/dev/null || true)
    if [[ -z "${PUBLIC_IPV6}" || "${DNS_IPV6}" != "${PUBLIC_IPV6}" ]]; then
        echo "Warning: AAAA record for ${HOST} does not match this VPS IPv6 (${PUBLIC_IPV6:-no public IPv6 detected}). Continuing with the verified IPv4 A record; remove or correct the stale AAAA record so IPv6 clients and future certificate validation reach this VPS." >&2
    fi
fi

# Let's Encrypt needs inbound HTTP before certificate issuance. install.sh
# opens these ports later for the VPN services, which is too late for this
# helper's ACME request.
if command -v iptables >/dev/null 2>&1; then
    allow_input_port() {
        local protocol="$1" port="$2" reject_line
        iptables -C INPUT -p "${protocol}" --dport "${port}" -m state --state NEW -j ACCEPT 2>/dev/null && return 0
        reject_line=$(iptables -L INPUT --line-numbers -n | awk '/REJECT/ {print $1; exit}')
        if [[ -n "${reject_line}" ]]; then
            iptables -I INPUT "${reject_line}" -p "${protocol}" --dport "${port}" -m state --state NEW -j ACCEPT
        else
            iptables -I INPUT 1 -p "${protocol}" --dport "${port}" -m state --state NEW -j ACCEPT
        fi
    }
    allow_input_port tcp 80
    allow_input_port tcp 443
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi
else
    echo "iptables is unavailable; ensure TCP port 80 is allowed by the host firewall before continuing." >&2
fi

apt-get install -y certbot
mkdir -p /var/www/html/.well-known/acme-challenge /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d
chmod 755 /var/www/html /var/www/html/.well-known /var/www/html/.well-known/acme-challenge
cat > /etc/nginx/conf.d/vpn-api-rate.conf <<'EOF'
limit_req_zone $binary_remote_addr zone=vpn_api:10m rate=10r/s;
EOF

SITE=/etc/nginx/sites-available/vpn-api
cat > "${SITE}" <<EOF
server {
    listen 80;
    server_name ${HOST};
    location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 404; }
}
EOF
ln -sf "${SITE}" /etc/nginx/sites-enabled/vpn-api
nginx -t
systemctl reload nginx

PROBE_TOKEN="vpn-api-acme-probe-$(date +%s)-$$"
PROBE_FILE="/var/www/html/.well-known/acme-challenge/${PROBE_TOKEN}"
printf '%s' "${PROBE_TOKEN}" >"${PROBE_FILE}"
chmod 644 "${PROBE_FILE}"
PROBE_BODY=$(curl --noproxy '*' -fsS --max-time 5 --resolve "${HOST}:80:127.0.0.1" \
    "http://${HOST}/.well-known/acme-challenge/${PROBE_TOKEN}" 2>/dev/null || true)
rm -f "${PROBE_FILE}"
if [[ "${PROBE_BODY}" != "${PROBE_TOKEN}" ]]; then
    echo "Nginx cannot serve the ACME webroot locally for ${HOST}; check for a conflicting port-80 virtual host or filesystem permissions." >&2
    exit 1
fi

if ! certbot certonly --webroot -w /var/www/html -d "${HOST}" --non-interactive --agree-tos -m "${EMAIL}" --keep-until-expiring; then
    echo "Certificate issuance failed; API remains loopback-only. Confirm TCP 80 is reachable through the cloud firewall/security list and that no CDN/proxy blocks /.well-known/acme-challenge/. Correct stale AAAA records too."
    exit 10
fi

cat > "${SITE}" <<EOF
server {
    listen 80;
    server_name ${HOST};
    location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    server_name ${HOST};
    ssl_certificate /etc/letsencrypt/live/${HOST}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${HOST}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 16k;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;
    location / {
        # Add allow <ip-web>; deny all; here to restrict source addresses.
        limit_req zone=vpn_api burst=10 nodelay;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:8088;
    }
}
EOF
if nginx -t; then
    systemctl reload nginx
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/vpn-api-reload-nginx <<'HOOK'
#!/bin/sh
systemctl reload nginx
HOOK
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/vpn-api-reload-nginx
    echo "Public HTTPS API enabled at https://${HOST}; 8088 remains bound to localhost."
else
    echo "Nginx validation failed. API remains loopback-only; repair ${SITE} before reloading Nginx." >&2
    exit 1
fi
