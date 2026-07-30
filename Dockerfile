# syntax=docker/dockerfile:1
#
# An isolated container for running Claude Code against everything under
# ~/Projects, with network access to DDEV projects via ddev-router.

FROM node:22-bookworm-slim

ARG USERNAME=dizzy
ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        composer \
        curl \
        git \
        gnupg \
        jq \
        less \
        nano \
        openssh-client \
        php-cli \
        php-curl \
        php-mbstring \
        php-xml \
        php-zip \
        procps \
        ripgrep \
        rsync \
        unzip \
        wget \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI only -- no daemon. It talks to the rootless dind sidecar over TCP,
# so the box can start containers without any access to the host's Docker.
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# The node image already owns uid/gid 1000. Replace that user with one matching
# the host user, so files written into the bind-mounted source tree keep the
# right ownership instead of coming out root-owned.
RUN userdel -r node >/dev/null 2>&1 || true; \
    groupadd -g "${GID}" "${USERNAME}"; \
    useradd -m -d "/home/${USERNAME}" -u "${UID}" -g "${GID}" -s /bin/bash "${USERNAME}"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# Preloaded into every node process by NODE_OPTIONS (see docker-compose.yaml).
# Baked into the image rather than bind-mounted: a bind-mounted single file can
# go stale in the container, and a preload that fails to resolve breaks every
# node process in the box, Claude Code included.
COPY node-proxy-bootstrap.cjs /usr/local/lib/claudebox/proxy-bootstrap.cjs
RUN chmod 0644 /usr/local/lib/claudebox/proxy-bootstrap.cjs

# `ddev` inside the box is a shim that forwards `ddev exec` to the ddev-relay
# over the internal network -- the box has no host Docker daemon and no real
# ddev. Baked in (not bind-mounted) so it is always on PATH ahead of anything.
COPY ddev-shim /usr/local/bin/ddev
RUN chmod 0755 /usr/local/bin/ddev

# Node has its own CA bundle and ignores the system store, so point it at the
# DDEV root CA that entrypoint.sh installs.
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/ddev-rootCA.crt
ENV BOX_USER=${USERNAME}
ENV HOME=/home/${USERNAME}

WORKDIR /home/${USERNAME}/Projects

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
