#!/bin/sh
#
# Add one public key to the workspace door's authorized_keys, or list what is
# already there.
#
# Baked into the image as /usr/local/bin/claudebox-sync-authorize and reached
# from the host by "claudebox mutagen authorize" / "claudebox mutagen status",
# which is a docker exec: the file lives in the state volume, so there is
# nothing on the host to edit and no second copy to drift.
set -eu

STATE="${CLAUDEBOX_SYNC_STATE:-/var/lib/claudebox-sync}"
KEYS="${STATE}/authorized_keys"

case "${1:-}" in
    --list)
        [ -f "${KEYS}" ] || exit 0
        # Fingerprint plus comment, not the key: what is wanted here is "which
        # machines can get in", and forty lines of base64 does not answer that.
        tmp="$(mktemp)"; trap 'rm -f "${tmp}"' EXIT
        while IFS= read -r line; do
            case "${line}" in ''|\#*) continue ;; esac
            printf '%s\n' "${line}" > "${tmp}"
            printf '  %s\n' "$(ssh-keygen -lf "${tmp}" 2>/dev/null || echo "(unreadable) ${line}")"
        done < "${KEYS}"
        exit 0
        ;;
esac

key="${1:-}"
if [ -z "${key}" ]; then
    echo "usage: claudebox-sync-authorize '<public key>' | --list" >&2
    exit 2
fi

# Validate before writing. An authorized_keys line that is not a key is not an
# error sshd reports anywhere the person who typed it will see -- it just
# silently never matches, and the mount on the other machine keeps failing with
# "Permission denied" for a reason nothing names.
tmp="$(mktemp)"
trap 'rm -f "${tmp}" "${tmp}.have"' EXIT
printf '%s\n' "${key}" > "${tmp}"
if ! ssh-keygen -lf "${tmp}" >/dev/null 2>&1; then
    echo "claudebox-sync: that is not a public key" >&2
    exit 1
fi

mkdir -p "${STATE}"
touch "${KEYS}"

# The key material only -- type and base64, dropping the comment -- so the same
# key offered under a different comment is recognised as already present rather
# than added a second time.
fp="$(ssh-keygen -lf "${tmp}" | awk '{print $2}')"
while IFS= read -r line; do
    case "${line}" in ''|\#*) continue ;; esac
    printf '%s\n' "${line}" > "${tmp}.have"
    have="$(ssh-keygen -lf "${tmp}.have" 2>/dev/null | awk '{print $2}' || true)"
    if [ -n "${have}" ] && [ "${have}" = "${fp}" ]; then
        echo "claudebox-sync: already authorised (${fp})" >&2
        exit 0
    fi
done < "${KEYS}"

printf '%s\n' "${key}" >> "${KEYS}"
chown root:root "${KEYS}"
chmod 0644 "${KEYS}"
echo "claudebox-sync: authorised ${fp}" >&2
