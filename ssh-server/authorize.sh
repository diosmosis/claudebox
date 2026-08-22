#!/bin/sh
#
# Add one public key to the workspace door's authorized_keys, or list what is
# already there.
#
# Baked into the image as /usr/local/bin/claudebox-ssh-authorize and reached
# from the host by "claudebox ssh authorize" / "claudebox ssh status", which is
# a docker exec: the file lives in the state volume, so there is nothing on the
# host to edit and no second copy to drift.
set -eu

STATE="${CLAUDEBOX_SSH_STATE:-/var/lib/claudebox-ssh}"
KEYS="${STATE}/authorized_keys"

case "${1:-}" in
    --list)
        [ -f "${KEYS}" ] || exit 0
        # Fingerprint plus comment, not the key: what is wanted here is "which
        # machines can get in", and forty lines of base64 does not answer that.
        while IFS= read -r line; do
            case "${line}" in ''|\#*) continue ;; esac
            printf '%s\n' "${line}" > /tmp/k.$$
            printf '  %s\n' "$(ssh-keygen -lf /tmp/k.$$ 2>/dev/null || echo "(unreadable) ${line}")"
            rm -f /tmp/k.$$
        done < "${KEYS}"
        exit 0
        ;;
esac

key="${1:-}"
if [ -z "${key}" ]; then
    echo "usage: claudebox-ssh-authorize '<public key>' | --list" >&2
    exit 2
fi

# Validate before writing. An authorized_keys line that is not a key is not an
# error sshd reports anywhere the person who typed it will see -- it just
# silently never matches, and the mount on the other machine keeps failing with
# "Permission denied" for a reason nothing names.
printf '%s\n' "${key}" > /tmp/newkey.$$
trap 'rm -f /tmp/newkey.$$' EXIT
if ! ssh-keygen -lf /tmp/newkey.$$ >/dev/null 2>&1; then
    echo "claudebox-ssh: that is not a public key" >&2
    exit 1
fi

mkdir -p "${STATE}"
touch "${KEYS}"

# The key material only -- type and base64, dropping the comment -- so the same
# key offered under a different comment is recognised as already present rather
# than added a second time.
fp="$(ssh-keygen -lf /tmp/newkey.$$ | awk '{print $2}')"
while IFS= read -r line; do
    case "${line}" in ''|\#*) continue ;; esac
    printf '%s\n' "${line}" > /tmp/have.$$
    have="$(ssh-keygen -lf /tmp/have.$$ 2>/dev/null | awk '{print $2}' || true)"
    rm -f /tmp/have.$$
    if [ -n "${have}" ] && [ "${have}" = "${fp}" ]; then
        echo "claudebox-ssh: already authorised (${fp})" >&2
        exit 0
    fi
done < "${KEYS}"

printf '%s\n' "${key}" >> "${KEYS}"
chown root:root "${KEYS}"
chmod 0644 "${KEYS}"
echo "claudebox-ssh: authorised ${fp}" >&2
