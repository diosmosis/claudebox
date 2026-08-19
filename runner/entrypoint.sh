#!/bin/sh
#
# claudebox-runner container entrypoint.
#
# Generates the runner's identity on first start -- a shared token and a
# self-signed certificate -- and drops to the box user before the service runs.
#
# Self-signed plus a pinned fingerprint rather than a CA: the only client is
# runner-relay on one other machine, and standing up a CA to serve one client
# buys nothing but a root key to look after. mkcert cannot help here either --
# its root lives on the other machine, not this one. So the runner IS its
# certificate: the join line prints the fingerprint, the relay pins it, and a
# certificate that changes is a runner that has to be re-joined, which is
# exactly the property wanted.
#
# The identity lives in a volume, so it survives restarts and rebuilds. Delete
# that volume to rotate it; the join line changes and the old one stops working.
set -eu

STATE="${CLAUDEBOX_RUNNER_STATE:-/var/lib/claudebox-runner}"
WORKSPACE="${CLAUDEBOX_RUNNER_WORKSPACE:-/home/dizzy/Projects}"
USERNAME="${BOX_USER:-dizzy}"

mkdir -p "${STATE}"

if [ ! -f "${STATE}/token" ]; then
    # 32 bytes. It is a bearer token on a home LAN behind a pinned certificate,
    # not a password anyone types.
    openssl rand -hex 32 > "${STATE}/token"
    chmod 0600 "${STATE}/token"
    echo "claudebox-runner: generated a new access token" >&2
fi

if [ ! -f "${STATE}/cert.pem" ] || [ ! -f "${STATE}/key.pem" ]; then
    # The subject is not checked by anything: the relay verifies the
    # fingerprint and nothing else, because on a home LAN there is no name to
    # verify that an attacker could not also claim. Ten years so this is not a
    # thing that quietly expires mid-session a year from now.
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=claudebox-runner" \
        -addext "subjectAltName=DNS:claudebox-runner,DNS:localhost,IP:127.0.0.1" \
        -keyout "${STATE}/key.pem" -out "${STATE}/cert.pem" >/dev/null 2>&1
    chmod 0600 "${STATE}/key.pem"
    echo "claudebox-runner: generated a new certificate" >&2
fi

# The fingerprint, in the exact form node reports as fingerprint256, so the
# relay's check is a string comparison and not a format conversion.
openssl x509 -in "${STATE}/cert.pem" -noout -fingerprint -sha256 \
    | sed 's/^.*Fingerprint=//' > "${STATE}/fingerprint"

chown -R "${USERNAME}:${USERNAME}" "${STATE}"

# Only the root of the workspace, not -R: it is a volume that will hold entire
# checkouts, and walking it on every start would cost more the more it holds.
# Everything inside it is written by this service as this user anyway.
mkdir -p "${WORKSPACE}"
chown "${USERNAME}:${USERNAME}" "${WORKSPACE}"

exec setpriv --reuid "${USERNAME}" --regid "${USERNAME}" --init-groups "$@"
