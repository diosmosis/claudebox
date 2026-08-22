#!/bin/sh
#
# claudebox workspace door entrypoint.
#
# Generates this door's identity on first start -- an ed25519 host key -- and
# settles the two things the image deliberately does not bake in: which user
# sshd lets in, and where that user's home is. Both are settings (BOX_USER,
# BOX_WORKSPACE) rather than properties of the image, and an image that had them
# compiled in would go silently wrong the moment either changed.
#
# The identity lives in a volume, so it survives restarts and rebuilds. Delete
# that volume to rotate it -- every machine that mounted this workspace has
# pinned the old fingerprint and will refuse to mount until it re-pins.
set -eu

STATE="${CLAUDEBOX_SSH_STATE:-/var/lib/claudebox-ssh}"
USER="${CLAUDEBOX_SSH_USER:-dizzy}"
WORKSPACE="${CLAUDEBOX_WORKSPACE:-/home/${USER}/Projects}"

mkdir -p "${STATE}"
chmod 0755 "${STATE}"

if [ ! -f "${STATE}/ssh_host_ed25519_key" ]; then
    ssh-keygen -q -t ed25519 -N '' -C claudebox-ssh \
        -f "${STATE}/ssh_host_ed25519_key"
    echo "claudebox-ssh: generated a new host key" >&2
fi
chmod 0600 "${STATE}/ssh_host_ed25519_key"
chmod 0644 "${STATE}/ssh_host_ed25519_key.pub"

# In the same form "ssh-keygen -lf" prints on the other machine, so comparing
# what this says with what the client pinned is a string comparison and not a
# format conversion. Written on every start rather than only on generation: it
# is derived, and a stale copy beside a rotated key would be the worst possible
# thing for it to be.
ssh-keygen -lf "${STATE}/ssh_host_ed25519_key.pub" | awk '{print $2}' \
    > "${STATE}/fingerprint"

# Root-owned and not writable by the user who logs in. That is the whole reason
# this file is out here rather than in ~/.ssh: the home directory is the shared
# workspace, writable by anyone already inside it, and a self-extending
# authorized_keys is not a door -- it is a doorway.
if [ ! -f "${STATE}/authorized_keys" ]; then
    : > "${STATE}/authorized_keys"
fi
chown root:root "${STATE}/authorized_keys"
chmod 0644 "${STATE}/authorized_keys"

# The home directory is the workspace, so "sshfs box@host:" with no path lands
# on the source tree -- the other machine does not have to know, or be told,
# where this one keeps it. Rewritten in place on every start because it tracks a
# setting; the field is the sixth of seven in the passwd line.
awk -F: -v u="${USER}" -v h="${WORKSPACE}" 'BEGIN{OFS=":"}
    $1 == u { $6 = h } { print }' /etc/passwd > /etc/passwd.new
mv /etc/passwd.new /etc/passwd
chmod 0644 /etc/passwd

# Unlock the account, without giving anyone a password to use.
#
# This sshd is Alpine's, built WITHOUT PAM, and without PAM it makes its own
# account-locked check before it ever looks at a key: an account whose password
# field is "!" or "*" is refused outright with "User x not allowed because
# account is locked". That field is exactly what "adduser -D" leaves behind, and
# what every keys-only account on an ordinary distro carries -- those work
# because their sshd runs with UsePAM yes, which skips the check. There is no
# PAM here to skip it.
#
# So the account gets a password that cannot be used rather than no password at
# all: 32 random bytes, regenerated on every start, never printed, and with
# PasswordAuthentication off in sshd_config. Satisfying the check by unlocking
# with an EMPTY password would be the other way, and would leave
# PermitEmptyPasswords as the only thing standing between the LAN and a shell.
printf '%s:%s\n' "${USER}" "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
    | chpasswd 2>/dev/null

# A missing workspace here means the bind source was missing on the host, which
# Docker answers by creating an empty root-owned directory rather than by
# failing. Serving that to another machine would look like a workspace that had
# lost every project in it, so say so instead.
if [ ! -d "${WORKSPACE}" ]; then
    echo "claudebox-ssh: the workspace ${WORKSPACE} is not mounted; refusing to serve" >&2
    exit 1
fi

sed "s|@USER@|${USER}|g" /etc/ssh/sshd_config.template > /etc/ssh/sshd_config
chmod 0600 /etc/ssh/sshd_config

if [ ! -s "${STATE}/authorized_keys" ]; then
    echo "claudebox-ssh: no keys authorised yet -- nothing can log in until" >&2
    echo "claudebox-ssh: 'claudebox ssh authorize <public key>' adds one." >&2
fi

exec "$@"
