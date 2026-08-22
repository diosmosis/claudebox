#!/bin/sh
#
# claudebox workspace door entrypoint.
#
# Generates this door's identity on first start -- an ed25519 host key -- and
# settles the three things the image deliberately does not bake in: which user
# sshd lets in, where that user's home is, and which tree is being served. All
# three follow settings (BOX_USER, BOX_WORKSPACE), and an image with them
# compiled in would go silently wrong the moment any of them changed.
#
# The identity lives in a volume, so it survives restarts and rebuilds. Delete
# that volume to rotate it -- every machine that ever attached to this workspace
# has pinned the old fingerprint and will refuse to attach until it re-pins.
set -eu

STATE="${CLAUDEBOX_SYNC_STATE:-/var/lib/claudebox-sync}"
USER="${CLAUDEBOX_SYNC_USER:-dizzy}"
WORKSPACE="${CLAUDEBOX_WORKSPACE:-/home/${USER}/Projects}"

mkdir -p "${STATE}"
chmod 0755 "${STATE}"

if [ ! -f "${STATE}/ssh_host_ed25519_key" ]; then
    ssh-keygen -q -t ed25519 -N '' -C claudebox-sync \
        -f "${STATE}/ssh_host_ed25519_key"
    echo "claudebox-sync: generated a new host key" >&2
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
# this file is out here rather than in ~/.ssh: a self-extending authorized_keys
# is not a door, it is a doorway.
if [ ! -f "${STATE}/authorized_keys" ]; then
    : > "${STATE}/authorized_keys"
fi
chown root:root "${STATE}/authorized_keys"
chmod 0644 "${STATE}/authorized_keys"

# The login user's home, on the state volume and emphatically NOT the workspace.
#
# It WAS the workspace, back when the other machine mounted this tree with sshfs
# and a home that *was* the tree meant "sshfs host:" needed no path. Mutagen
# changes that completely: it installs its agent by scp'ing a binary into the
# login user's home and running it there. A home that is the source tree means a
# ~20MB mutagen-agent appearing inside the workspace on first attach -- and then
# being synced out to every machine attached to it, forever, as a file nobody
# put there.
#
# So it moves here: writable, outside anything anyone syncs, and persistent, so
# the agent is copied once rather than on every reconnect. The state directory
# itself stays root-owned, which is what keeps authorized_keys out of reach of a
# login session; only this subdirectory belongs to the user.
HOME_DIR="${STATE}/home/${USER}"
mkdir -p "${HOME_DIR}"
chown "${USER}:${USER}" "${HOME_DIR}"
chmod 0700 "${HOME_DIR}"
awk -F: -v u="${USER}" -v h="${HOME_DIR}" 'BEGIN{OFS=":"}
    $1 == u { $6 = h } { print }' /etc/passwd > /etc/passwd.new
mv /etc/passwd.new /etc/passwd
chmod 0644 /etc/passwd

# Which tree is served, published for the other machine to read over ssh with
# claudebox-sync-info. It used to be implicit -- the home directory was the
# tree, so there was nothing to say -- and now that home is deliberately
# somewhere else, the path has to be stated. The alternative is the two machines
# agreeing on BOX_WORKSPACE by luck.
printf '%s\n' "${WORKSPACE}" > "${STATE}/served-workspace"

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

# A missing workspace means the bind source was missing on the host, which
# Docker answers by creating an empty root-owned directory rather than by
# failing.
if [ ! -d "${WORKSPACE}" ]; then
    echo "claudebox-sync: the workspace ${WORKSPACE} is not mounted; refusing to serve" >&2
    exit 1
fi

# And an EMPTY workspace is refused too, which is new and is the single most
# important line in this file.
#
# Under sshfs an empty served tree meant the other machine saw nothing --
# annoying, and that was all. Under a two-way sync it means something far worse:
# this door is one end of a reconciler, and "present over there, absent here" is
# propagated as a DELETION. two-way-safe does not save you, because removing a
# file that was not modified on the other side is not a conflict -- it is an
# unambiguous delete. Serving an empty tree tells the attached machine that
# every file it has was deleted, and it will oblige.
#
# The realistic way to be here is a workspace on a drive that did not mount.
if [ -z "$(ls -A -- "${WORKSPACE}" 2>/dev/null)" ] \
   && [ "${CLAUDEBOX_SYNC_ALLOW_EMPTY:-}" != "1" ]; then
    {
        echo "claudebox-sync: the workspace ${WORKSPACE} is EMPTY, and this door is one end"
        echo "claudebox-sync: of a two-way sync -- serving it would tell the machine attached"
        echo "claudebox-sync: to it that every file it has was deleted, and it would delete"
        echo "claudebox-sync: them. Refusing."
        echo "claudebox-sync:"
        echo "claudebox-sync: If the tree lives on a drive, mount it. If this really is a new"
        echo "claudebox-sync: and empty workspace, set CLAUDEBOX_SYNC_ALLOW_EMPTY=1."
    } >&2
    exit 1
fi

sed "s|@USER@|${USER}|g" /etc/ssh/sshd_config.template > /etc/ssh/sshd_config
chmod 0600 /etc/ssh/sshd_config

if [ ! -s "${STATE}/authorized_keys" ]; then
    echo "claudebox-sync: no keys authorised yet -- nothing can log in until" >&2
    echo "claudebox-sync: 'claudebox mutagen authorize <public key>' adds one." >&2
fi

exec "$@"
