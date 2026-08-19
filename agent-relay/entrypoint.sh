#!/bin/sh
#
# claudebox agent front door entrypoint.
#
# Generates this machine's identity on first start -- a shared token and a
# self-signed certificate. Byte for byte the same scheme as
# runner/entrypoint.sh, because it is the same problem seen from the other end:
# there, the runner IS its certificate and this machine pins it; here, this
# machine is its certificate and the runner machine pins it.
#
# Self-signed plus a pinned fingerprint rather than a CA: there is one client on
# one LAN, and standing up a CA to serve it buys nothing but a root key to look
# after. mkcert's root is on this machine, but the other machine has no reason
# to trust it either, so it would only move the pinning problem.
#
# The identity lives in a volume, so it survives restarts and rebuilds. Delete
# that volume to rotate it; the join line changes and the old one stops working.
set -eu

STATE="${CLAUDEBOX_AGENT_STATE:-/var/lib/claudebox-agent}"

mkdir -p "${STATE}"

if [ ! -f "${STATE}/token" ]; then
    # 32 bytes. It is a bearer token on a home LAN behind a pinned certificate,
    # not a password anyone types.
    openssl rand -hex 32 > "${STATE}/token"
    chmod 0600 "${STATE}/token"
    echo "claudebox-agent: generated a new access token" >&2
fi

if [ ! -f "${STATE}/cert.pem" ] || [ ! -f "${STATE}/key.pem" ]; then
    # The subject is not checked by anything: the client verifies the
    # fingerprint and nothing else, because on a home LAN there is no name to
    # verify that an attacker could not also claim. Ten years so this is not a
    # thing that quietly expires mid-session a year from now.
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=claudebox-agent" \
        -addext "subjectAltName=DNS:claudebox-agent,DNS:localhost,IP:127.0.0.1" \
        -keyout "${STATE}/key.pem" -out "${STATE}/cert.pem" >/dev/null 2>&1
    chmod 0600 "${STATE}/key.pem"
    echo "claudebox-agent: generated a new certificate" >&2
fi

# The fingerprint, in the exact form node reports as fingerprint256, so the
# client's check is a string comparison and not a format conversion.
openssl x509 -in "${STATE}/cert.pem" -noout -fingerprint -sha256 \
    | sed 's/^.*Fingerprint=//' > "${STATE}/fingerprint"

# Only while this machine has never been joined -- a workstation that restarts
# daily should not re-open a window every day. "claudebox agent enrol" is how
# you open one deliberately. Same script both ways, so there is one definition
# of what a window is.
if [ ! -f "${STATE}/enrolled" ]; then
    /usr/local/bin/claudebox-agent-enrol
fi

exec "$@"
