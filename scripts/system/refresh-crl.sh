#!/bin/bash
set -euo pipefail
CA_DIR=/etc/openvpn/easy-rsa
cd "$CA_DIR"
./easyrsa --batch gen-crl
install -o root -g nogroup -m 0644 pki/crl.pem /etc/openvpn/crl.pem
install -o root -g nogroup -m 0644 pki/crl.pem /etc/openvpn/server/crl.pem
