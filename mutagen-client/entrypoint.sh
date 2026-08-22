#!/bin/sh
#
# claudebox syncer entrypoint.
#
# Generates the two things this image deliberately does not bake in: this
# machine's ssh identity, and the ssh config that points mutagen at the door.
#
# Both are rewritten on every start rather than only when absent. The config is
# derived from CLAUDEBOX_SYNC_HOST/PORT/USER, which change when the machine
# attaches somewhere else, and a stale config beside a changed setting is the
# worst thing it could be: mutagen would go on talking to the old address with
# nothing anywhere indicating it had been told otherwise.
set -eu

STATE="${CLAUDEBOX_MUTAGEN_STATE:-/var/lib/claudebox-mutagen}"
IDENT="${CLAUDEBOX_SYNC_CLIENT_DIR:-/var/lib/claudebox-sync-client}"
KEY="${IDENT}/id_ed25519"
KNOWN="${IDENT}/known_hosts"

umask 077
mkdir -p "${STATE}/home/.ssh" "${IDENT}"
chmod 0700 "${IDENT}" "${STATE}/home/.ssh"

# This machine's key -- its own, rather than anything under the user's ~/.ssh.
# claudebox generating a key without being asked has no business putting it
# where a person keeps theirs, and a key that exists only for this makes "which
# machines can reach my workspace" answerable from one authorized_keys file.
#
# It lives on a HOST bind, not in the state volume, and that is deliberate: it
# is an identity other machines have authorised, so "docker volume prune" must
# not be a way to make every door on the LAN stop letting this machine in.
if [ ! -f "${KEY}" ]; then
    ssh-keygen -q -t ed25519 -N '' \
        -C "claudebox@${CLAUDEBOX_SYNC_LABEL:-unknown}" -f "${KEY}"
    echo "claudebox-mutagen: generated this machine's key" >&2
fi
chmod 0600 "${KEY}"
chmod 0644 "${KEY}.pub" 2>/dev/null || true
touch "${KNOWN}"
chmod 0600 "${KNOWN}"

# The whole reason this runs in a container.
#
# Mutagen takes no ssh options; it reads this file, and only this file, because
# HOME here is ours. StrictHostKeyChecking=yes against a known_hosts of our own
# is what turns "trust on first sight" into "checked every time after"; the
# launcher pins the door's key into that file before a session is ever created.
# BatchMode=yes is what makes a refused key an error rather than a password
# prompt nobody is watching -- this runs under a daemon, with no terminal.
#
# ControlMaster no: mutagen opens one long-lived connection per endpoint plus
# short-lived ones while installing an agent, and a shared control socket in a
# container that gets recreated leaves stale sockets behind.
cat > "${STATE}/home/.ssh/config" <<CONF
Host claudebox-door
    HostName ${CLAUDEBOX_SYNC_HOST:-invalid.invalid}
    Port ${CLAUDEBOX_SYNC_PORT:-7994}
    User ${CLAUDEBOX_SYNC_USER:-root}
    IdentityFile ${KEY}
    IdentitiesOnly yes
    UserKnownHostsFile ${KNOWN}
    GlobalKnownHostsFile /dev/null
    StrictHostKeyChecking yes
    BatchMode yes
    PasswordAuthentication no
    ServerAliveInterval 15
    ServerAliveCountMax 3
    ControlMaster no
CONF
chmod 0600 "${STATE}/home/.ssh/config"

if [ -z "${CLAUDEBOX_SYNC_HOST:-}" ]; then
    echo "claudebox-mutagen: no door address set yet; 'claudebox mutagen attach' sets one" >&2
fi

exec "$@"
