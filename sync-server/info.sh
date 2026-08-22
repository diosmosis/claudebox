#!/bin/sh
#
# What the other machine needs to know, asked over ssh in one round trip:
#
#   ssh <door> /usr/local/bin/claudebox-sync-info
#
# It replaces two things sshfs did implicitly.
#
# It is the AUTHENTICATION PROBE: it either prints, or ssh says "Permission
# denied (publickey)". That is the state every new machine starts in, and the
# one sshfs described worst -- it swallowed the real error and reported
# "read: Connection reset by peer".
#
# And it is where the SERVED PATH comes from. sshfs needed no path because the
# login user's home WAS the tree; the home is deliberately somewhere else now
# (see entrypoint.sh), so the path has to be stated rather than guessed from the
# other machine's own BOX_WORKSPACE.
#
# Call it by absolute path. sshd's PATH for a non-interactive command on Alpine
# does not include /usr/local/bin, so the bare name fails with "command not
# found" on a perfectly working door.
set -eu

STATE="${CLAUDEBOX_SYNC_STATE:-/var/lib/claudebox-sync}"
WORKSPACE="$(cat "${STATE}/served-workspace")"

printf 'protocol=1\n'
printf 'workspace=%s\n' "${WORKSPACE}"
printf 'user=%s\n' "$(id -un)"
printf 'fingerprint=%s\n' "$(cat "${STATE}/fingerprint")"

# Whether there is anything there, so the attaching machine can refuse before it
# creates a session rather than after. The door refuses to START over an empty
# tree for the same reason -- see entrypoint.sh -- but a drive can be unmounted
# while the door is up, and that window is exactly when someone attaches.
if [ -n "$(ls -A -- "${WORKSPACE}" 2>/dev/null)" ]; then
    printf 'empty=no\n'
else
    printf 'empty=yes\n'
fi
