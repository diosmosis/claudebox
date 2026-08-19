# The rootless dind sidecar's one host prerequisite, detected rather than
# documented. Sourced by both launchers -- this machine's `claudebox` and the
# target machine's `claudebox-runner`. Not executable on its own.
#
# Ubuntu 24.04 sets kernel.apparmor_restrict_unprivileged_userns=1, which denies
# unprivileged user-namespace creation to UNCONFINED processes. rootlesskit
# creates one before dockerd starts, so under that restriction the sidecar dies
# immediately with
#
#   [rootlesskit:parent] error: failed to start the child:
#   fork/exec /proc/self/exe: operation not permitted
#
# apparmor/claudebox-dind grants it to that one container and is the whole fix.
# What makes this worth code rather than a line in a README is where the symptom
# surfaces: the container exits 1, compose reports only that a dependency is
# unhealthy, and the actual message is four layers down in a log nobody thinks
# to open. It cost a full debugging round here, and it would cost the same again
# on the runner machine, where there is no agent sitting next to you.
#
# Two checks, because they fail at different times and neither covers the other:
#
#   preflight   cheap and predictive, before anything starts -- but it can only
#               see that the profile FILE is installed, not that it was ever
#               loaded (/sys/kernel/security/apparmor/profiles is root-only, so
#               a launcher running as the user cannot confirm that).
#   postmortem  authoritative and catches every variant, including "file present
#               but apparmor_parser never ran" -- but only after a failure.
#
# Callers set these first; both launchers use the same text with their own
# checkout's path in it, so the printed commands are copy-pasteable in place.
: "${DIND_APPARMOR_TAG:=claudebox}"
: "${DIND_APPARMOR_DIR:=.}"
: "${DIND_APPARMOR_CONTAINER:=claudebox-dind}"

# The whole fix, not a pointer to documentation. Both paths print exactly this.
dind_apparmor_fix() {
    local t="${DIND_APPARMOR_TAG}"
    cat >&2 <<EOF
${t}: the dind sidecar cannot create a user namespace, which rootless
${t}: dockerd needs before it can start. Ubuntu 24.04 denies this to
${t}: unconfined processes (kernel.apparmor_restrict_unprivileged_userns=1).
${t}: Install the profile that grants it to this one container:
${t}:   sudo cp ${DIND_APPARMOR_DIR}/apparmor/claudebox-dind /etc/apparmor.d/
${t}:   sudo apparmor_parser -r /etc/apparmor.d/claudebox-dind
${t}: Then run this again. See apparmor/claudebox-dind for why this rather
${t}: than turning the restriction off for the whole host.
EOF
}

# Whether the named profile is what the stack will actually ask for. Someone who
# has set BOX_DIND_APPARMOR=unconfined -- a host with no AppArmor confinement at
# all, which is how this ran under Docker Desktop -- has opted out, and neither
# check below has anything to say to them.
dind_apparmor_in_use() {
    [ "${BOX_DIND_APPARMOR:-claudebox-dind}" = "claudebox-dind" ]
}

# Before `compose up`. Exits non-zero on the one condition that is certain to
# fail: the restriction is on and the profile is not installed, in which case
# Docker cannot even find it to apply. Absent sysctl, a 0, or no AppArmor at all
# all mean there is nothing to do.
dind_apparmor_preflight() {
    local restricted
    dind_apparmor_in_use || return 0
    restricted="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)"
    [ "${restricted}" = "1" ] || return 0
    [ -f /etc/apparmor.d/claudebox-dind ] || {
        dind_apparmor_fix
        exit 1
    }
}

# After a failed start. Returns 0 when it recognised this failure (and has
# printed the fix), so the caller can exit on it rather than on whatever
# compose said.
dind_apparmor_postmortem() {
    dind_apparmor_in_use || return 1
    docker logs "${DIND_APPARMOR_CONTAINER}" 2>&1 \
        | grep -q 'fork/exec /proc/self/exe: operation not permitted' || return 1
    dind_apparmor_fix
    return 0
}
