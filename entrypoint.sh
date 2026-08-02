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

# Make "localhost:<port>" here mean what it means on a single-host CI runner.
#
# A container started inside dind publishes its ports onto DIND's interface, not
# this one, so wp-env's WordPress comes up at dind:8888 and anything expecting
# localhost:8888 -- Puppeteer, or a screenshot baseline generated on a runner --
# finds nothing. Forward each requested port from this container's loopback to
# dind so both spellings work.
#
# Loopback-bound on purpose: this is a convenience for processes in the box, not
# a service for the network. Nothing is bridged that the box could not already
# reach, since dind is a NO_PROXY host it talks to directly.
if [ -n "${CLAUDEBOX_DIND_PORTS:-}" ]; then
    forwarded=""
    for port in $(printf '%s' "${CLAUDEBOX_DIND_PORTS}" | tr ',' ' '); do
        case "${port}" in
            ''|*[!0-9]*)
                echo "claudebox: ignoring non-numeric CLAUDEBOX_DIND_PORTS entry '${port}'" >&2
                continue
                ;;
        esac
        # setsid so the forwarder is not in this shell's process group and
        # cannot be taken down with it; it must outlive the entrypoint's exec.
        setsid socat "TCP-LISTEN:${port},bind=127.0.0.1,fork,reuseaddr" \
                     "TCP:dind:${port}" >/dev/null 2>&1 &
        forwarded="${forwarded} ${port}"
    done
    if [ -n "${forwarded}" ]; then
        echo "claudebox: localhost ->dind for port(s):${forwarded}"
    fi
fi

# Hand the proxy to every nested container without anyone having to remember it.
#
# The Docker CLI injects proxies.default into each container it creates -- both
# "docker run" and "docker compose up", which is what wp-env drives -- so a
# nested stack reaches the allowlist with no per-command flags and no changes to
# the tool that starts it.
#
# It must be the proxy's ADDRESS, not its name: dind's embedded DNS knows
# nothing about claudebox_inner, so "proxy" does not resolve inside a nested
# container. Rewritten on every start, because that address changes whenever the
# proxy container is recreated.
#
# Merged into whatever is already there rather than overwriting: this file also
# holds registry credentials.
proxy_ip="$(getent hosts proxy 2>/dev/null | awk '{print $1; exit}' || true)"
if [ -n "${proxy_ip}" ]; then
    docker_cfg="${USER_HOME}/.docker/config.json"
    mkdir -p "${USER_HOME}/.docker"
    if [ ! -s "${docker_cfg}" ]; then
        echo '{}' > "${docker_cfg}"
    fi
    # host.docker.internal has to be in noProxy, not on the allowlist. It is an
    # address on claudebox_inner that the container reaches directly; sending it
    # to Squid gets a 403, because Squid neither resolves that name (it is a
    # per-container extra_hosts entry, not DNS) nor should be in that path at
    # all. Without it, WordPress's requests to Matomo fail in a way that looks
    # like a blocked domain.
    if jq --arg p "http://${proxy_ip}:3128" \
        '.proxies.default = {
             httpProxy:  $p,
             httpsProxy: $p,
             noProxy:    "localhost,127.0.0.1,::1,host.docker.internal,dind,proxy,ddev-relay"
         }' "${docker_cfg}" > "${docker_cfg}.tmp" 2>/dev/null; then
        mv "${docker_cfg}.tmp" "${docker_cfg}"
    else
        rm -f "${docker_cfg}.tmp"
        echo "claudebox: could not write ${docker_cfg}; nested containers get no proxy" >&2
    fi
    chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.docker"
else
    echo "claudebox: could not resolve the proxy; nested containers get no proxy" >&2
fi

# The named HOME volume starts out root-owned; fix its top level.
chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}"

# Then sweep out anything root-owned deeper in. Not hypothetical: the image sets
# HOME=/home/<user> for every user, so a single "docker exec -u 0 ..." that
# happens to run npm leaves root-owned files inside ~/.npm/_cacache. Every later
# npm run as the box user then fails with EACCES, several directories away from
# anything that looks like the cause -- and a top-level check does not see it,
# because ~/.npm itself stays correctly owned.
#
# Two paths are pruned, both host binds that are not ours to rewrite: ~/Projects
# is the source tree, and ~/.claude/plans is the host's plans directory, whose
# files can legitimately appear as uid 0 in here through Docker Desktop's file
# sharing while being correctly owned on the host.
USER_UID="$(id -u "${USER_NAME}")"
USER_GID="$(id -g "${USER_NAME}")"
fixed="$(find "${USER_HOME}" \
    -path "${USER_HOME}/Projects" -prune -o \
    -path "${USER_HOME}/.claude/plans" -prune -o \
    \( ! -uid "${USER_UID}" -o ! -gid "${USER_GID}" \) \
    -exec chown -h "${USER_NAME}:${USER_NAME}" {} + -print 2>/dev/null | wc -l)"
if [ "${fixed}" -gt 0 ]; then
    echo "claudebox: reclaimed ${fixed} root-owned file(s) under ${USER_HOME}"
fi

: > "${READY}"
exec "$@"
