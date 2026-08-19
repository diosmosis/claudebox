#!/bin/sh
#
# Open an enrolment window on this runner: a fresh short code, a fresh expiry,
# and the failure counter reset.
#
# Baked into the runner image as /usr/local/bin/claudebox-runner-enrol. Called by
# the entrypoint on a runner that has never been joined, and by
# "claudebox-runner enrol" on the machine's console to open one deliberately.
#
# See the note in runner/entrypoint.sh for what the code protects and what it
# does not.
set -eu

STATE="${CLAUDEBOX_RUNNER_STATE:-/var/lib/claudebox-runner}"
USERNAME="${BOX_USER:-dizzy}"
SECONDS_OPEN="${CLAUDEBOX_RUNNER_ENROL_SECONDS:-900}"

mkdir -p "${STATE}"

# The alphabet leaves out 0/O and 1/l/I: this exists to be read off one screen
# and typed into another. tr -dc over /dev/urandom is a uniform draw from the
# accepted set.
LC_ALL=C tr -dc '23456789abcdefghjkmnpqrstuvwxyz' < /dev/urandom \
    | head -c 8 > "${STATE}/enrol-code" || true

printf '%s' "$(( $(date +%s) + SECONDS_OPEN ))" > "${STATE}/enrol-expires"
rm -f "${STATE}/enrol-failures"

chmod 0600 "${STATE}/enrol-code" "${STATE}/enrol-expires"
# The service runs as the box user and reads these per request.
if [ "$(id -u)" = "0" ]; then
    chown "${USERNAME}:${USERNAME}" "${STATE}/enrol-code" "${STATE}/enrol-expires"
fi
