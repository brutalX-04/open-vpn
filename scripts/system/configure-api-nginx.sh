#!/bin/bash
set -euo pipefail

HOST="${1:-}"
EMAIL="${2:-}"
if [[ ! "${HOST}" =~ ^[A-Za-z0-9.-]+$ || ! "${EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo "Invalid public API hostname or email." >&2
    exit 2
fi

apt-get install -y certbot
mkdir -p /var/www/html/.well-known/acme-challenge /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d
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

if ! certbot certonly --webroot -w /var/www/html -d "${HOST}" --non-interactive --agree-tos -m "${EMAIL}" --keep-until-expiring; then
    echo "Certificate issuance failed; API remains loopback-only. HTTP virtual host only serves ACME challenges and 404 responses."
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
