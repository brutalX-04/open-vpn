#!/bin/bash
# Expiry cleanup is owned by the shared vpnctl library.
exec /usr/bin/vpn-cli cleanup "$@"
