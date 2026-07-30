#!/usr/bin/env bash
# Runs as root at container start, then hands off to CMD.
set -euo pipefail

USER_NAME="${BOX_USER:-dizzy}"
USER_HOME="/home/${USER_NAME}"
READY=/run/claudebox.ready

# The launcher waits on this; clear it before doing any setup work.
rm -f "${READY}"

# Trust DDEV's mkcert root CA so https://*.ddev.site validates inside the box.
if [ -f /host/mkcert/rootCA.pem ]; then
    install -m 0644 /host/mkcert/rootCA.pem /usr/local/share/ca-certificates/ddev-rootCA.crt
    update-ca-certificates >/dev/null 2>&1 || true
fi

# Seed the box's Claude config from the host once. The host copies are mounted
# read-only, so the box gets your settings/skills but can never write back.
seed() {
    local src="$1" dest="$2"
    if [ ! -e "$dest" ] && [ -e "$src" ]; then
        cp -a "$src" "$dest"
        chown -R "${USER_NAME}:${USER_NAME}" "$dest"
        echo "claudebox: seeded ${dest} from host"
    fi
    return 0
}

# ~/.claude carries per-machine history that would be misleading in the box
# (and slow to copy), so take the portable parts only: settings, skills,
# commands, agents, plugins, memory.
if [ ! -e "${USER_HOME}/.claude" ] && [ -d /host/claude ]; then
    rsync -a \
        --exclude=projects/ \
        --exclude=shell-snapshots/ \
        --exclude=todos/ \
        --exclude=file-history/ \
        --exclude=statsig/ \
        --exclude=logs/ \
        /host/claude/ "${USER_HOME}/.claude/"
    chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.claude"
    echo "claudebox: seeded ~/.claude from host"
fi

seed /host/claude.json "${USER_HOME}/.claude.json"
seed /host/gitconfig "${USER_HOME}/.gitconfig"

# The named HOME volume starts out root-owned; fix just its top level. Never
# recurse -- ~/Projects is the bind-mounted host source tree.
chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}"

: > "${READY}"
exec "$@"
