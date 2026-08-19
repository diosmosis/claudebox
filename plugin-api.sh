# shellcheck shell=bash
#
# claudebox plugin API -- the shared half of the launcher.
#
# Sourced by two different kinds of process, which is the whole point:
#
#   - the launcher itself, for the handful of things a plugin also needs
#     (translating paths, building the "docker exec" flags a session is
#     attached with), so there is one implementation rather than two that
#     drift;
#   - a plugin command, which is a separate executable and cannot inherit the
#     launcher's functions any other way. The launcher exports
#     CLAUDEBOX_PLUGIN_API pointing here, so a plugin starts with:
#
#         . "${CLAUDEBOX_PLUGIN_API}"
#
# Everything below reads its inputs from the environment the launcher exports
# (CLAUDEBOX_* and BOX_*), so this file holds functions and nothing else -- no
# top-level state, no set -e, no assumptions about who sourced it. A plugin
# written in something other than bash gets the same information from the same
# variables and simply does without the helpers.
#
# See "claudebox plugins" for what is installed and CLAUDEBOX.md for the
# contract these functions are half of.

# Sourcing this twice is not an error -- a plugin may source it after the
# launcher already did in a parent process that exec'd it -- but redefining
# functions for nothing is noise, so make it a no-op.
if [ -n "${CLAUDEBOX_PLUGIN_API_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
CLAUDEBOX_PLUGIN_API_LOADED=1

# The names the launcher exports, defaulted here as well so that sourcing this
# file in isolation (a plugin's own test, say) fails with something legible
# rather than with "unbound variable" under set -u.
: "${CLAUDEBOX_DIR:=}"
: "${CLAUDEBOX_CONTAINER:=claudebox}"
: "${CLAUDEBOX_PROXY_CONTAINER:=claudebox-proxy}"
: "${CLAUDEBOX_COMPOSE_FILES:=}"

# ---------------------------------------------------------------------------
# Talking to the user
#
# The launcher prefixes everything it says with "claudebox: ". A plugin's
# messages say which plugin they came from as well, because "claudebox: cannot
# find it" from a command the user installed themselves is a support question
# with no answer in this repository.
# ---------------------------------------------------------------------------
plugin_label() {
    if [ -n "${CLAUDEBOX_PLUGIN:-}" ]; then
        printf 'claudebox: %s:%s' "${CLAUDEBOX_PLUGIN}" "${CLAUDEBOX_PLUGIN_COMMAND:-?}"
    else
        printf 'claudebox'
    fi
}

plugin_say() {
    printf '%s: %s\n' "$(plugin_label)" "$*" >&2
}

plugin_die() {
    plugin_say "$@"
    exit 1
}

# A per-plugin scratch directory, created on demand.
#
# It lives under the launcher's own plugins directory rather than beside the
# plugin, so that a plugin installed from somewhere read-only -- or kept in its
# own git checkout, where a state directory would show up as untracked noise --
# still has somewhere to write. Printed, not exported, so a plugin that never
# calls this never has a directory created for it.
plugin_state() {
    local dir="${CLAUDEBOX_PLUGIN_STATE:-}"
    [ -n "${dir}" ] || { plugin_say "no state directory: not running as a plugin command"; return 1; }
    mkdir -p "${dir}" || return 1
    printf '%s\n' "${dir}"
}

# ---------------------------------------------------------------------------
# Paths
#
# The workspace has two of them and they are only the same by default: the box
# sees BOX_WORKSPACE, the host directory bound there is BOX_WORKSPACE_HOST.
# Anything outside that tree has no counterpart at all -- the workspace is the
# only host tree bound in -- which is a failure, not a path to guess at.
# ---------------------------------------------------------------------------
box_path() {
    case "${1}" in
        "${BOX_WORKSPACE_HOST}")   printf '%s\n' "${BOX_WORKSPACE}" ;;
        "${BOX_WORKSPACE_HOST}"/*) printf '%s\n' "${BOX_WORKSPACE}${1#"${BOX_WORKSPACE_HOST}"}" ;;
        *) return 1 ;;
    esac
}

# The reverse: a path the box printed, turned back into one that can be opened
# on the host. Useful for a plugin that runs something in the box and then
# reports where its output landed.
host_path() {
    case "${1}" in
        "${BOX_WORKSPACE}")   printf '%s\n' "${BOX_WORKSPACE_HOST}" ;;
        "${BOX_WORKSPACE}"/*) printf '%s\n' "${BOX_WORKSPACE_HOST}${1#"${BOX_WORKSPACE}"}" ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# The box
# ---------------------------------------------------------------------------

# Is the container up and answering? "docker exec true" rather than a state
# query: a container can be "running" while its entrypoint is still seeding
# HOME, and what callers actually want to know is whether they can exec.
box_running() {
    docker exec "${CLAUDEBOX_CONTAINER}" true 2>/dev/null
}

# Wait for the entrypoint's readiness flag, the same way the launcher does
# before attaching a session. "up -d" returns when the container has started,
# not when it is usable, and exec'ing in too early lands in a half-built HOME.
box_wait_ready() {
    local i
    for i in $(seq 1 "${1:-120}"); do
        if docker exec "${CLAUDEBOX_CONTAINER}" test -f /run/claudebox.ready 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

box_require_running() {
    if box_running; then
        return 0
    fi
    plugin_say "the box is not running; start it (claudebox, or 'claudebox shell -c true')"
    exit 1
}

# Bring the stack up by asking the launcher to, rather than by running compose
# here: starting the box also means the workspace checks, the dind AppArmor
# preflight, the allowlist resync and the DDEV hostname rewrite, and a plugin
# that reimplemented any of that would get a subtly different box from the one a
# session gets. "shell -c true" is a session that does nothing.
box_start() {
    [ -n "${CLAUDEBOX_DIR}" ] || { plugin_say "CLAUDEBOX_DIR is unset"; return 1; }
    box_running && return 0
    "${CLAUDEBOX_DIR}/claudebox" shell -c true >&2
}

# compose, against both files the launcher uses. Passing -f at all turns off
# Compose's automatic discovery of the override, so both have to be named.
box_compose() {
    local -a files=()
    local f
    while IFS= read -r f; do
        [ -n "${f}" ] && files+=(-f "${f}")
    done <<< "${CLAUDEBOX_COMPOSE_FILES}"
    docker compose ${files[@]+"${files[@]}"} "$@"
}

# ---------------------------------------------------------------------------
# Running things in the box
#
# box_exec_flags fills the BOX_EXEC_FLAGS array with the flags a session is
# attached with; the launcher's own attach path uses it too, which is why it
# lives here. Argument: the working directory, as the box sees it.
# ---------------------------------------------------------------------------
box_exec_flags() {
    local workdir="${1:-${BOX_WORKSPACE}}" proxy_ip

    BOX_EXEC_FLAGS=(-i -u "${BOX_UID}:${BOX_GID}" -w "${workdir}")
    if [ -t 0 ] && [ -t 1 ]; then
        BOX_EXEC_FLAGS+=(-t)
    fi

    # Terminal capabilities. "docker exec -t" sets TERM=xterm and nothing else,
    # which leaves a full-screen TUI (opencode's especially) drawing in eight
    # colours.
    #
    # The host's TERM is only passed through when the image has a terminfo entry
    # for it. Modern terminals ship their own -- ghostty is xterm-ghostty, kitty
    # is xterm-kitty -- and Debian's ncurses has neither, so forwarding blindly
    # would trade dull colours for curses programs in the box (less, nano)
    # failing on an unknown terminal type. COLORTERM carries the truecolor
    # answer both agents actually look at, and needs no terminfo at all.
    if [ -n "${TERM:-}" ] && docker exec "${CLAUDEBOX_CONTAINER}" infocmp "${TERM}" >/dev/null 2>&1; then
        BOX_EXEC_FLAGS+=(-e "TERM=${TERM}")
    else
        BOX_EXEC_FLAGS+=(-e "TERM=xterm-256color")
    fi
    if [ -n "${COLORTERM:-}" ]; then
        BOX_EXEC_FLAGS+=(-e "COLORTERM=${COLORTERM}")
    fi

    # Nested containers route out through the dind sidecar's network namespace,
    # so they can reach the proxy but can't resolve its name (dind's embedded
    # DNS doesn't know about it). Hand the box the address so it can pass the
    # proxy to "docker run" when a nested container needs egress:
    #   docker run -e HTTPS_PROXY=$CLAUDEBOX_PROXY ...
    proxy_ip="$(docker inspect -f \
        '{{ with index .NetworkSettings.Networks "claudebox_inner" }}{{ .IPAddress }}{{ end }}' \
        "${CLAUDEBOX_PROXY_CONTAINER}" 2>/dev/null || true)"
    if [ -n "${proxy_ip}" ]; then
        BOX_EXEC_FLAGS+=(-e "CLAUDEBOX_PROXY=http://${proxy_ip}:3128")
    fi
}

# The counterpart of the current directory inside the box, falling back to the
# root of the tree when the caller is somewhere the box cannot see -- the same
# rule a session starts under.
box_workdir() {
    local mapped
    if mapped="$(box_path "${1:-${PWD}}")"; then
        printf '%s\n' "${mapped}"
    else
        printf '%s\n' "${BOX_WORKSPACE}"
    fi
}

# box_exec [-w <dir>] <command> [args...]
#
# Runs a command in the box as the box user, in the current directory's
# counterpart unless -w says otherwise. -w takes either side's path: a host path
# is translated, anything else is passed through as the box's own.
box_exec() {
    local workdir=""
    while [ $# -gt 0 ]; do
        case "${1}" in
            -w) workdir="${2:-}"; shift 2 ;;
            --) shift; break ;;
            *)  break ;;
        esac
    done
    if [ -n "${workdir}" ]; then
        workdir="$(box_path "${workdir}" 2>/dev/null || printf '%s\n' "${workdir}")"
    else
        workdir="$(box_workdir)"
    fi
    box_require_running
    box_exec_flags "${workdir}"
    docker exec "${BOX_EXEC_FLAGS[@]}" "${CLAUDEBOX_CONTAINER}" "$@"
}

# The same, as root in the box. For the rare thing that needs it -- installing a
# package for the length of a session, fixing ownership -- and deliberately a
# separate call so that "as root" is visible at the call site.
box_exec_root() {
    local workdir=""
    while [ $# -gt 0 ]; do
        case "${1}" in
            -w) workdir="${2:-}"; shift 2 ;;
            --) shift; break ;;
            *)  break ;;
        esac
    done
    if [ -n "${workdir}" ]; then
        workdir="$(box_path "${workdir}" 2>/dev/null || printf '%s\n' "${workdir}")"
    else
        workdir="$(box_workdir)"
    fi
    box_require_running
    box_exec_flags "${workdir}"
    # Replace the -u the flags carry rather than appending: later flags do not
    # override earlier ones in docker exec's parser.
    local -a flags=() f
    local skip=""
    for f in "${BOX_EXEC_FLAGS[@]}"; do
        if [ -n "${skip}" ]; then skip=""; continue; fi
        if [ "${f}" = "-u" ]; then skip=1; continue; fi
        flags+=("${f}")
    done
    docker exec -u 0:0 "${flags[@]}" "${CLAUDEBOX_CONTAINER}" "$@"
}
