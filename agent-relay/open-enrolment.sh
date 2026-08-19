#!/bin/sh
#
# Open an enrolment window on this machine: a fresh short code, a fresh expiry,
# and the failure counter reset.
#
# Baked into the front door image as /usr/local/bin/claudebox-agent-enrol.
# Called by entrypoint.sh on a machine that has never been joined, and by
# "claudebox agent enrol" to open one deliberately.
#
# What the code protects and what it does not:
#
#   Single-use and short-lived, so another host on this network cannot connect
#   during the window and walk away with a token that grants it a claude session
#   in this box. That is the attack worth closing.
#
#   The certificate is trusted on first sight by whoever enrols. An attacker
#   already ON the path at that moment could present its own and keep MITMing
#   thereafter -- the same residual risk ssh accepts the first time it shows you
#   a host key, and why every request after enrolment is pinned.
#
# The alphabet leaves out 0/O and 1/l/I: this exists to be read off one screen
# and typed into another.
set -eu

STATE="${CLAUDEBOX_AGENT_STATE:-/var/lib/claudebox-agent}"
SECONDS_OPEN="${CLAUDEBOX_AGENT_ENROL_SECONDS:-900}"

mkdir -p "${STATE}"

LC_ALL=C tr -dc '23456789abcdefghjkmnpqrstuvwxyz' < /dev/urandom \
    | head -c 8 > "${STATE}/enrol-code" || true
expires=$(( $(date +%s) + SECONDS_OPEN ))
printf '%s\n' "${expires}" > "${STATE}/enrol-expires"
rm -f "${STATE}/enrol-failures"

code="$(cat "${STATE}/enrol-code")"
minutes=$(( SECONDS_OPEN / 60 ))

{
    echo
    echo "claudebox: enrolment is open for ${minutes} minutes. On the RUNNER machine, run:"
    echo
    echo "    claudebox agent add <this-machine>:${CLAUDEBOX_AGENT_PORT:-7996} ${code}"
    echo
    echo "That machine will then send its headless one-off runs here instead of"
    echo "running an agent on itself. The code is single use."
    echo
} >&2
