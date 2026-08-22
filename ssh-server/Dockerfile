# syntax=docker/dockerfile:1
#
# The claudebox workspace door: an sshd that serves the SAME source tree the box
# works in, so another machine on this LAN can mount it with sshfs and run its
# own claudebox over it.
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

# openssh-sftp-server is not optional and not pulled in by openssh-server:
# sshfs speaks the sftp subsystem, and without it every mount fails at
# "subsystem request failed on channel 0" with the ssh login itself working
# fine, which is a confusing way to find out.
RUN apk add --no-cache openssh-server openssh-sftp-server shadow

# The same uid/gid the box runs as, so a file written through sshfs from the
# other machine lands with the ownership everything else in the tree already
# has. A mismatch here does not fail loudly; it just leaves the remote machine
# writing files the local box cannot modify.
#
# The home directory is set at RUNTIME by entrypoint.sh, not here: it is the
# workspace path, which is a setting (BOX_WORKSPACE) rather than a property of
# the image. Baking it in would mean an image that is silently wrong -- pointing
# at a directory that no longer exists -- after that setting changes, with no
# rebuild to notice it.
RUN set -eux; \
    if getent group "${GID}" >/dev/null; then \
        groupmod -n "${USERNAME}" "$(getent group "${GID}" | cut -d: -f1)"; \
    else \
        addgroup -g "${GID}" "${USERNAME}"; \
    fi; \
    adduser -D -H -h "/home/${USERNAME}" -u "${UID}" -G "${USERNAME}" -s /bin/ash "${USERNAME}"

COPY sshd_config.template /etc/ssh/sshd_config.template
COPY entrypoint.sh /usr/local/bin/claudebox-ssh-entrypoint
COPY authorize.sh /usr/local/bin/claudebox-ssh-authorize
RUN chmod 0755 /usr/local/bin/claudebox-ssh-entrypoint /usr/local/bin/claudebox-ssh-authorize

EXPOSE 22

# -D: stay in the foreground. -e: log to stderr, so "docker logs claudebox-ssh"
# is where a refused key is explained instead of a file nobody looks in.
CMD ["/usr/local/bin/claudebox-ssh-entrypoint", "/usr/sbin/sshd", "-D", "-e"]
