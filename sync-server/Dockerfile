# syntax=docker/dockerfile:1
#
# The claudebox workspace door: an sshd over the SAME source tree the box works
# in, so another machine on this LAN can keep a live local copy of it with
# mutagen and run its own claudebox against that copy.
#
# This is only mutagen's transport. Nothing mutagen-shaped is installed here --
# the other machine scp's an agent binary into this container's home and runs it
# over ssh, which is what "mutagen must not be installed on either host" comes
# down to in practice. See mutagen-client/ for the other end.
#
# Deliberately not the box image with sshd bolted on. The box has the agent, the
# egress proxy variables, a Docker client pointed at dind and a route onto
# `inner`; a login shell in there would hand all of it to whoever holds the key.
# This container has one mount and one network, and knows nothing about the rest
# of the stack -- see docker-compose.yaml, where it is on `edge` alone.

FROM alpine:3.20

ARG USERNAME=dizzy
ARG UID=1000
ARG GID=1000

# openssh-sftp-server is not optional and not pulled in by openssh-server: it is
# the subsystem scp lands on, and mutagen installs its agent with scp. Without
# it the ssh login works fine and the agent copy fails at "subsystem request
# failed on channel 0", which is a confusing way to find out.
#
# openssh-client is for scp's LEGACY protocol, which executes an `scp` binary on
# the SERVER. A client old enough to use it, or one invoked with -O, otherwise
# fails at "scp: command not found" halfway through installing an agent. It is
# about a megabyte, and that is not a megabyte worth saving.
RUN apk add --no-cache openssh-server openssh-sftp-server openssh-client shadow

# The same uid/gid the box runs as, so a file written through the sync from the
# other machine lands with the ownership everything else in the tree already
# has. A mismatch here does not fail loudly; it just leaves the remote machine
# writing files the local box cannot modify.
#
# The home directory is set at RUNTIME by entrypoint.sh, not here: it lives on
# the state volume, and the path depends on settings. See the long note there on
# why it must not be the workspace.
RUN set -eux; \
    if getent group "${GID}" >/dev/null; then \
        groupmod -n "${USERNAME}" "$(getent group "${GID}" | cut -d: -f1)"; \
    else \
        addgroup -g "${GID}" "${USERNAME}"; \
    fi; \
    adduser -D -H -h "/home/${USERNAME}" -u "${UID}" -G "${USERNAME}" -s /bin/ash "${USERNAME}"

COPY sshd_config.template /etc/ssh/sshd_config.template
COPY entrypoint.sh /usr/local/bin/claudebox-sync-entrypoint
COPY authorize.sh /usr/local/bin/claudebox-sync-authorize
COPY info.sh /usr/local/bin/claudebox-sync-info
RUN chmod 0755 /usr/local/bin/claudebox-sync-entrypoint \
                /usr/local/bin/claudebox-sync-authorize \
                /usr/local/bin/claudebox-sync-info

EXPOSE 22

# -D: stay in the foreground. -e: log to stderr, so "docker logs claudebox-sync"
# is where a refused key is explained instead of a file nobody looks in.
CMD ["/usr/local/bin/claudebox-sync-entrypoint", "/usr/sbin/sshd", "-D", "-e"]
