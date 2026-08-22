# syntax=docker/dockerfile:1
#
# The claudebox syncer: a mutagen daemon and an ssh client, in a container.
#
# Why a container rather than two binaries on the host is not tidiness. Mutagen
# shells out to the system ssh and accepts NO per-session ssh options -- no
# identity file, no port, no known-hosts file. Everything it needs has to come
# out of an ssh config file, and the only one it will read is $HOME/.ssh/config
# for whoever it runs as. On the host that is the person's own ssh config, which
# this tool has no business writing to. In here $HOME is ours, so the config is
# generated from scratch on every start and points at claudebox's own key and
# its own pinned known_hosts. Nothing under the user's ~/.ssh is read or
# written.
#
# It also means the borrowing machine needs no host tooling at all: no mutagen,
# no sshfs, no FUSE, no ssh. And the far end needs nothing installed either --
# mutagen scp's an agent binary into the door container's home and runs it
# there, which is why the agent BUNDLE below is not optional. Without it this
# image can sync local directories and nothing else.

# ---------------------------------------------------------------------------
FROM alpine:3.20 AS fetch

ARG MUTAGEN_VERSION=0.18.1
# Supplied by buildx. Named so an architecture mutagen does not publish fails
# here, loudly, rather than 404ing halfway down.
ARG TARGETARCH=amd64

RUN apk add --no-cache curl

RUN set -eux; \
    url="https://github.com/mutagen-io/mutagen/releases/download/v${MUTAGEN_VERSION}/mutagen_linux_${TARGETARCH}_v${MUTAGEN_VERSION}.tar.gz"; \
    curl -fsSL -o /tmp/mutagen.tgz "${url}"; \
    mkdir -p /out; \
    tar -xzf /tmp/mutagen.tgz -C /out; \
    # Both files, and the second is the one that is easy to lose. The tarball
    # ships the CLI/daemon binary AND mutagen-agents.tar.gz, which holds agent
    # builds for every platform mutagen can drive. Mutagen finds that bundle by
    # looking NEXT TO ITS OWN EXECUTABLE, so the two travel together or remote
    # sync fails at "unable to locate agent bundle" with the daemon otherwise
    # perfectly healthy. Asserted rather than assumed.
    test -x /out/mutagen; \
    test -s /out/mutagen-agents.tar.gz

# ---------------------------------------------------------------------------
FROM alpine:3.20

ARG USERNAME=dizzy
ARG UID=1000
ARG GID=1000

# openssh-client for ssh and scp, which mutagen invokes; ssh-keygen and
# ssh-keyscan for generating this machine's key and pinning the door's host key.
# Those two have moved between Alpine subpackages before now, so their presence
# is asserted at build time -- a package split should be a build failure, not a
# failure three commands into an attach.
RUN apk add --no-cache openssh-client openssh-keygen ca-certificates \
 && for t in ssh scp ssh-keygen ssh-keyscan; do \
        command -v "$t" >/dev/null || { echo "missing $t" >&2; exit 1; }; \
    done

COPY --from=fetch /out/mutagen /usr/local/bin/mutagen
COPY --from=fetch /out/mutagen-agents.tar.gz /usr/local/bin/mutagen-agents.tar.gz
RUN chmod 0755 /usr/local/bin/mutagen

# Smoke test at build time. Mutagen's linux builds are static Go binaries, so
# they run on musl -- but "so they should" is not a thing to discover on the
# machine that has already thrown its sshfs away.
RUN mutagen version

# The same uid/gid the box runs as. Files mutagen writes into the local copy
# land through a bind, so their ownership is the HOST's ownership, and a
# mismatch here produces a workspace the box cannot write to.
RUN set -eux; \
    if getent group "${GID}" >/dev/null; then \
        groupmod -n "${USERNAME}" "$(getent group "${GID}" | cut -d: -f1)" 2>/dev/null \
            || sed -i "s/^[^:]*:\\([^:]*\\):${GID}:/${USERNAME}:\\1:${GID}:/" /etc/group; \
    else \
        addgroup -g "${GID}" "${USERNAME}"; \
    fi; \
    adduser -D -H -h /var/lib/claudebox-mutagen/home -u "${UID}" -G "${USERNAME}" -s /bin/ash "${USERNAME}"

# Pre-created and pre-owned, and that is what makes "user:" in compose work
# without a root entrypoint: Docker seeds a NEW named volume from whatever the
# image has at that path, ownership included. A container starting as the
# unprivileged user against a root-owned empty volume could not fix it.
RUN mkdir -p /var/lib/claudebox-mutagen/home/.ssh /var/lib/claudebox-sync-client \
 && chown -R "${UID}:${GID}" /var/lib/claudebox-mutagen /var/lib/claudebox-sync-client \
 && chmod 0700 /var/lib/claudebox-mutagen/home/.ssh

COPY entrypoint.sh /usr/local/bin/claudebox-mutagen-entrypoint
RUN chmod 0755 /usr/local/bin/claudebox-mutagen-entrypoint

ENV HOME=/var/lib/claudebox-mutagen/home

# "daemon run", not "daemon start": run stays in the foreground, which is what a
# container needs. "start" forks and returns, and a container whose main process
# has returned is a container that has stopped -- taking the daemon it just
# started with it.
CMD ["/usr/local/bin/claudebox-mutagen-entrypoint", "mutagen", "daemon", "run"]
