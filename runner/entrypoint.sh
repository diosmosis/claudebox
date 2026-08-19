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

# HOME is a named volume, seeded from the image the first time. Docker gets the
# ownership right when it seeds, but not after a uid change, so assert it.
HOME_DIR="$(getent passwd "${USERNAME}" | cut -d: -f6)"
chown "${USERNAME}:${USERNAME}" "${HOME_DIR}"

as_user() {
    setpriv --reuid "${USERNAME}" --regid "${USERNAME}" --init-groups \
        env HOME="${HOME_DIR}" "$@"
}

# ---------------------------------------------------------------------------
# DDEV
#
# ddev is a docker client, and DOCKER_HOST points at the sidecar, so every
# project container it starts lives in there. Two global settings make that
# arrangement work; both are written once and then left alone, so they can be
# edited in the volume without a rebuild undoing it.
# ---------------------------------------------------------------------------
if [ ! -f "${HOME_DIR}/.ddev/global_config.yaml" ]; then
    as_user mkdir -p "${HOME_DIR}/.ddev"
    as_user tee "${HOME_DIR}/.ddev/global_config.yaml" >/dev/null <<'YAML'
# Written once by claudebox-runner on first start. Edit freely; it is in a
# volume and will not be overwritten.

# The one setting this arrangement cannot work without. Project ports -- the
# router's 80/443 above all -- are published on the DAEMON's interface, and the
# daemon is the dind sidecar, a different container from the one ddev runs in.
# Bound to 127.0.0.1 (the default) they are reachable only from inside the
# sidecar, so the runner sees nothing listening and every request to a project
# is refused for a reason that looks like the project failing to start.
router_bind_all_interfaces: true

# Plain bind mounts. Mutagen is for macOS and Windows filesystems and has
# nothing to do on Linux, and a sync layer between the tree and the web
# container is the last thing wanted when the tree itself arrived over a
# network.
performance_mode: none

# No telemetry from a machine whose whole job is running someone else's tests.
instrumentation_opt_in: false
YAML
    echo "claudebox-runner: wrote ${HOME_DIR}/.ddev/global_config.yaml" >&2
fi

# ---------------------------------------------------------------------------
# The mkcert root for this machine's DDEV projects
#
# The box trusts the HOST's mkcert root, because the projects it talks to are
# started by that host. This machine starts its own, so there is no other root
# to agree with -- it generates one and trusts it itself. It lives in HOME,
# which is a volume, because re-issuing it would re-issue every project
# certificate with it.
#
# The CAROOT has to be visible to the sidecar's daemon as well: `ddev start`
# pushes the root into its global cache with a container that BINDS this
# directory, and that bind is resolved over there. docker-compose.runner.yaml
# mounts this HOME into the sidecar at the same path for exactly that reason.
# ---------------------------------------------------------------------------
CAROOT="${HOME_DIR}/.local/share/mkcert"
if [ ! -f "${CAROOT}/rootCA.pem" ]; then
    as_user mkdir -p "${CAROOT}"
    as_user env CAROOT="${CAROOT}" mkcert -install >/dev/null 2>&1 || true
    if [ -f "${CAROOT}/rootCA.pem" ]; then
        echo "claudebox-runner: generated a mkcert root CA for this machine's DDEV projects" >&2
    else
        echo "claudebox-runner: warning: mkcert could not create a root CA; DDEV will serve" >&2
        echo "claudebox-runner: untrusted certificates and https:// to a project will fail" >&2
    fi
fi
# Into the system store on every start, not only when generated: the store is in
# the image layer and a container recreate throws it away while the volume keeps
# the CA. NODE_EXTRA_CA_CERTS (see the compose file) points at this same path,
# since node ignores the system store.
if [ -f "${CAROOT}/rootCA.pem" ]; then
    install -m 0644 "${CAROOT}/rootCA.pem" /usr/local/share/ca-certificates/ddev-rootCA.crt
    update-ca-certificates >/dev/null 2>&1 || true
fi

exec setpriv --reuid "${USERNAME}" --regid "${USERNAME}" --init-groups "$@"
