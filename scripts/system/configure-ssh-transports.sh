#!/bin/bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
fi

CONFIG_FILE=/etc/vpn/config.conf
read_config() {
    local key="$1"
    awk -F= -v key="${key}" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "${CONFIG_FILE}" 2>/dev/null || true
}

DOMAIN=$(read_config DOMAIN)
DROPBEAR_PORTS_RAW=$(read_config PORT_DROPBEAR)
STUNNEL_PORTS_RAW=$(read_config PORT_STUNNEL)
DROPBEAR_PORTS_RAW=${DROPBEAR_PORTS_RAW:-143,109}
STUNNEL_PORTS_RAW=${STUNNEL_PORTS_RAW:-447,777}

validate_ports() {
    local value="$1" name="$2" port
    [[ "${value}" =~ ^[0-9]+(,[0-9]+)*$ ]] || {
        echo "Invalid ${name} port list: ${value}" >&2
        return 1
    }
    IFS=',' read -r -a ports <<<"${value}"
    for port in "${ports[@]}"; do
        ((port > 0 && port < 65536)) || {
            echo "Port out of range in ${name}: ${port}" >&2
            return 1
        }
    done
    printf '%s\n' "${ports[@]}"
}

mapfile -t DROPBEAR_PORTS < <(validate_ports "${DROPBEAR_PORTS_RAW}" Dropbear)
mapfile -t STUNNEL_PORTS < <(validate_ports "${STUNNEL_PORTS_RAW}" Stunnel)
if [[ -z "${DROPBEAR_PORTS[*]}" || -z "${STUNNEL_PORTS[*]}" ]]; then
    echo "Dropbear and Stunnel need at least one listen port each." >&2
    exit 1
fi

if [[ -n "${DOMAIN}" && ! "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "Invalid DOMAIN in ${CONFIG_FILE}." >&2
    exit 1
fi

CERTIFICATE_CHANGED=0
DROPBEAR_CONFIG_CHANGED=0
STUNNEL_CONFIG_CHANGED=0

write_certificate_bundle() {
    local bundle=/etc/stunnel/vpn-ssh.pem tmp cert_dir common_name
    tmp=$(mktemp /etc/stunnel/vpn-ssh.pem.XXXXXX)
    if [[ -n "${DOMAIN}" \
        && -r "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" \
        && -r "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]]; then
        cat "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" \
            "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" >"${tmp}"
        echo "Using the Let's Encrypt certificate for ${DOMAIN}."
    else
        if [[ -s "${bundle}" ]]; then
            rm -f "${tmp}"
            echo "Keeping the existing Stunnel certificate until a Let's Encrypt certificate is available."
            return 0
        fi
        cert_dir=$(mktemp -d /etc/stunnel/vpn-ssh-cert.XXXXXX)
        common_name=${DOMAIN:-localhost}
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=${common_name}" \
            -keyout "${cert_dir}/key.pem" -out "${cert_dir}/cert.pem" >/dev/null 2>&1
        cat "${cert_dir}/cert.pem" "${cert_dir}/key.pem" >"${tmp}"
        rm -f "${cert_dir}/key.pem" "${cert_dir}/cert.pem"
        rmdir "${cert_dir}"
        echo "No Let's Encrypt certificate exists for ${DOMAIN:-this VM}; using a temporary self-signed certificate for Stunnel."
    fi
    chown root:root "${tmp}"
    chmod 0600 "${tmp}"
    if [[ -r "${bundle}" ]] && cmp -s "${tmp}" "${bundle}"; then
        rm -f "${tmp}"
    else
        mv -f "${tmp}" "${bundle}"
        CERTIFICATE_CHANGED=1
    fi
}

refresh_certificate() {
    if [[ -z "${DOMAIN}" \
        || ! -r "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" \
        || ! -r "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]]; then
        echo "No Let's Encrypt certificate is available for ${DOMAIN:-this VM}." >&2
        exit 1
    fi
    write_certificate_bundle
    if [[ "${CERTIFICATE_CHANGED}" == "1" ]]; then
        if systemctl is-active --quiet stunnel4.service; then
            systemctl reload stunnel4.service || systemctl restart stunnel4.service
        else
            systemctl restart stunnel4.service
        fi
    elif ! systemctl is-active --quiet stunnel4.service; then
        systemctl restart stunnel4.service
    fi
}

install_renewal_hook() {
    local hook=/etc/letsencrypt/renewal-hooks/deploy/vpn-stunnel-reload
    mkdir -p "$(dirname "${hook}")"
    cat >"${hook}" <<'EOF'
#!/bin/bash
set -euo pipefail
CONFIG_FILE=/etc/vpn/config.conf
DOMAIN=$(awk -F= '$1 == "DOMAIN" {sub(/^[^=]*=/, ""); print; exit}' "${CONFIG_FILE}" 2>/dev/null || true)
[[ -n "${DOMAIN}" && "${RENEWED_LINEAGE:-}" == "/etc/letsencrypt/live/${DOMAIN}" ]] || exit 0
exec /etc/vpn/scripts/system/configure-ssh-transports.sh --refresh-certificate
EOF
    chmod 0755 "${hook}"
}

install_renewal_hook

if [[ "${1:-}" == "--refresh-certificate" ]]; then
    refresh_certificate
    exit 0
elif [[ -n "${1:-}" ]]; then
    echo "Usage: $0 [--refresh-certificate]" >&2
    exit 2
fi

mkdir -p /etc/systemd/system/dropbear.service.d /etc/stunnel
DROPBEAR_EXTRA_ARGS=""
for port in "${DROPBEAR_PORTS[@]:1}"; do
    DROPBEAR_EXTRA_ARGS+="-p ${port} "
done
DROPBEAR_EXTRA_ARGS=${DROPBEAR_EXTRA_ARGS% }
DROPBEAR_CONFIG=/etc/systemd/system/dropbear.service.d/10-vpn-panel-ports.conf
DROPBEAR_CONFIG_TMP=$(mktemp "${DROPBEAR_CONFIG}.XXXXXX")
cat >"${DROPBEAR_CONFIG_TMP}" <<EOF
[Service]
Environment=DROPBEAR_PORT=${DROPBEAR_PORTS[0]}
Environment="DROPBEAR_EXTRA_ARGS=${DROPBEAR_EXTRA_ARGS}"
EOF
if [[ -r "${DROPBEAR_CONFIG}" ]] && cmp -s "${DROPBEAR_CONFIG_TMP}" "${DROPBEAR_CONFIG}"; then
    rm -f "${DROPBEAR_CONFIG_TMP}"
else
    install -m 0644 "${DROPBEAR_CONFIG_TMP}" "${DROPBEAR_CONFIG}"
    rm -f "${DROPBEAR_CONFIG_TMP}"
    DROPBEAR_CONFIG_CHANGED=1
fi

write_certificate_bundle
STUNNEL_CONFIG=/etc/stunnel/vpn-ssh.conf
STUNNEL_CONFIG_TMP=$(mktemp "${STUNNEL_CONFIG}.XXXXXX")
{
    cat <<'EOF'
pid = /run/stunnel4/vpn-ssh.pid
cert = /etc/stunnel/vpn-ssh.pem
sslVersionMin = TLSv1.2

EOF
    for port in "${STUNNEL_PORTS[@]}"; do
        printf '[ssh-%s]\naccept = 0.0.0.0:%s\nconnect = 127.0.0.1:22\n\n' "${port}" "${port}"
    done
} >"${STUNNEL_CONFIG_TMP}"
if [[ -r "${STUNNEL_CONFIG}" ]] && cmp -s "${STUNNEL_CONFIG_TMP}" "${STUNNEL_CONFIG}"; then
    rm -f "${STUNNEL_CONFIG_TMP}"
else
    install -m 0644 "${STUNNEL_CONFIG_TMP}" "${STUNNEL_CONFIG}"
    rm -f "${STUNNEL_CONFIG_TMP}"
    STUNNEL_CONFIG_CHANGED=1
fi

allow_input_port() {
    local port="$1" reject_line
    iptables -C INPUT -p tcp --dport "${port}" -m state --state NEW -j ACCEPT 2>/dev/null && return 0
    reject_line=$(iptables -L INPUT --line-numbers -n | awk '/REJECT/ {print $1; exit}')
    if [[ -n "${reject_line}" ]]; then
        iptables -I INPUT "${reject_line}" -p tcp --dport "${port}" -m state --state NEW -j ACCEPT
    else
        iptables -I INPUT 1 -p tcp --dport "${port}" -m state --state NEW -j ACCEPT
    fi
}

for port in "${DROPBEAR_PORTS[@]}" "${STUNNEL_PORTS[@]}"; do
    allow_input_port "${port}"
done
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
fi

if [[ "${DROPBEAR_CONFIG_CHANGED}" == "1" ]]; then
    systemctl daemon-reload
fi
systemctl enable dropbear.service stunnel4.service >/dev/null
if [[ "${DROPBEAR_CONFIG_CHANGED}" == "1" ]] || ! systemctl is-active --quiet dropbear.service; then
    systemctl restart dropbear.service
fi
if [[ "${STUNNEL_CONFIG_CHANGED}" == "1" || "${CERTIFICATE_CHANGED}" == "1" ]] \
    || ! systemctl is-active --quiet stunnel4.service; then
    systemctl restart stunnel4.service
fi
echo "Dropbear listens on TCP ${DROPBEAR_PORTS_RAW}; Stunnel TLS listens on TCP ${STUNNEL_PORTS_RAW}."
