# syntax=docker/dockerfile:1
#
# claudebox-runner: the box's environment minus the agent, plus a network API.
#
# FROM the base stage of the repo's main Dockerfile, and that is the entire
# point of this image. Matomo's UI baselines are sensitive to font PACKAGE
# VERSIONS -- fonts-dejavu-core 2.37-6 against 2.37-8 renders every glyph a
# pixel off -- so an environment assembled independently on the runner machine
# would produce screenshot diffs that look exactly like real regressions. Coming
# off the same layers as the box makes that parity structural instead of a thing
# to keep in step by hand.
#
# The base image is not published anywhere; the claudebox-runner launcher builds
# it from the checkout on this machine first, which is why it is an ARG rather
# than a hard-coded tag.
ARG BASE_IMAGE=claudebox-base:latest
FROM ${BASE_IMAGE}

# What may be installed here, and what may not.
#
# The rule is about what a TEST CAN OBSERVE. Fonts, PHP, node, Chromium's
# libraries, ImageMagick's limits -- anything that changes how code builds or
# how a pixel comes out -- belongs in base, where both images get the same
# layers. Something missing for a test is a base problem, never a runner one.
#
# An orchestrator is a different thing. DDEV starts containers from PULLED
# images; the environment a DDEV-backed test actually runs in is
# ddev/ddev-webserver, which is byte-identical wherever it is pulled. So the
# ddev binary itself is invisible to a test and belongs here -- the box has no
# real ddev at all (it has a shim onto the host's), so putting it in base would
# also put a second, conflicting `ddev` on the box's PATH.
#
# The VERSION is not invisible, though: a different ddev pulls different
# ddev-webserver and dbserver images. Pin it to whatever runs on the machine the
# baselines came from -- `ddev version` there -- and move both together.
#
# The release tarball rather than DDEV's install.sh: that script refuses to run
# as root ("This script must NOT be run with sudo/root"), which is exactly what
# a Dockerfile RUN is, and it also installs docker-compose and wants to touch
# the host's /etc/hosts. The tarball is the binary and nothing else.
ARG DDEV_VERSION=v1.25.3
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    asset="ddev_linux-${arch}.${DDEV_VERSION}.tar.gz"; \
    base="https://github.com/ddev/ddev/releases/download/${DDEV_VERSION}"; \
    curl -fsSL -o "/tmp/${asset}" "${base}/${asset}"; \
    curl -fsSL -o /tmp/checksums.txt "${base}/checksums.txt"; \
    grep " ${asset}\$" /tmp/checksums.txt > /tmp/ddev.sha256; \
    test -s /tmp/ddev.sha256; \
    (cd /tmp && sha256sum -c ddev.sha256); \
    tar -xzf "/tmp/${asset}" -C /usr/local/bin ddev ddev-hostname mkcert; \
    rm -f "/tmp/${asset}" /tmp/checksums.txt /tmp/ddev.sha256; \
    chmod 0755 /usr/local/bin/ddev /usr/local/bin/ddev-hostname /usr/local/bin/mkcert; \
    test -x /usr/local/bin/ddev
# No `ddev version` here to prove it works: every ddev subcommand connects to a
# Docker daemon first, and there is none during a build. The checksum is what is
# verified instead; the runner's healthcheck is what proves the daemon end.
#
# Three binaries out of the one tarball, and taking them together is deliberate:
#
#   ddev-hostname  `ddev start` shells out to it and FAILS HARD without it
#                  ("Binary not found: ddev-hostname is not installed"). It is
#                  what writes the project's names into /etc/hosts -- and here
#                  that matters more than usual, because DDEV points them at the
#                  Docker daemon's address and the daemon is the sidecar, so
#                  these entries are what makes https://<project>.ddev.site mean
#                  the router rather than this container.
#   mkcert         the version DDEV expects, rather than a separately pinned
#                  release that could drift from it. entrypoint.sh generates
#                  this machine's root CA with it on first start.

# Prepares a DDEV project's web container to behave like the single-host CI
# runner Matomo's UI-test baselines came from: client IP and path alias. The
# same script the box has, unchanged -- it drives `ddev exec`, which here is the
# real thing rather than the box's shim onto the host.
COPY ddev-fixups /usr/local/bin/claudebox-ddev-fixups
COPY ddev-realip.conf /usr/local/share/claudebox/ddev-realip.conf
RUN chmod 0755 /usr/local/bin/claudebox-ddev-fixups \
 && chmod 0644 /usr/local/share/claudebox/ddev-realip.conf

# sudo, for one binary and one binary only.
#
# `ddev start` refuses to run without ddev-hostname, and ddev-hostname insists on
# elevating -- it checks its own euid rather than whether it can write the file,
# so making /etc/hosts writable does not satisfy it. What it wants to write is
# right: DDEV resolves the DAEMON's address and points the project's names at it,
# which here is the sidecar, which is where the router is published.
#
# Not in base: the box deliberately has no sudo, and this is a property of the
# runner's role rather than of the shared environment. Scoped to the one command
# rather than a blanket NOPASSWD ALL -- /exec is already arbitrary code execution
# as this user, so this is hygiene, not a boundary, and hygiene is cheap.
RUN apt-get update \
 && apt-get install -y --no-install-recommends sudo \
 && rm -rf /var/lib/apt/lists/* \
 && printf '%s ALL=(root) NOPASSWD: /usr/local/bin/ddev-hostname\n' "${BOX_USER}" \
      > /etc/sudoers.d/claudebox-ddev-hostname \
 && chmod 0440 /etc/sudoers.d/claudebox-ddev-hostname \
 && visudo -c >/dev/null

# Points this container at a running project: the project's hostnames at the
# sidecar where the DDEV router is published, and `db:3306` at its database.
# The runner's counterpart to the box's ddev-db service and the proxy's
# rewritten /etc/hosts, neither of which applies when the project's containers
# are a level down inside the sidecar. See the script.
COPY ddev-bridge /usr/local/bin/claudebox-ddev-bridge
RUN chmod 0755 /usr/local/bin/claudebox-ddev-bridge

# The same nginx configuration the box's ddev-http service is built from, shipped
# as a template the bridge renders and hands to a stock nginx inside the sidecar.
#
# Shared rather than reimplemented, because what is in it is the load-bearing
# part: the Host rewrite, and X-Real-IP/X-Forwarded-For set to 127.0.0.1 so the
# project records visits from the address a single-host CI runner would. A second
# copy of that would drift, and the drift would show up as screenshot diffs.
#
# Not built as an image here: this container runs inside the sidecar's daemon,
# which cannot see images built out here and has no registry to pull a local one
# from. Stock nginx:alpine plus a rendered config over a bind mount avoids both.
COPY ddev-http/default.conf.template /usr/local/share/claudebox/ddev-http.conf.template
RUN chmod 0644 /usr/local/share/claudebox/ddev-http.conf.template

COPY runner/runner.mjs /app/runner.mjs
COPY runner/entrypoint.sh /usr/local/bin/runner-entrypoint.sh
COPY runner/open-enrolment.sh /usr/local/bin/claudebox-runner-enrol
RUN chmod 0755 /usr/local/bin/runner-entrypoint.sh /usr/local/bin/claudebox-runner-enrol

# Fail fast and loudly rather than restarting into a broken state.
ENV NODE_OPTIONS=--unhandled-rejections=strict

EXPOSE 7998
ENTRYPOINT ["/usr/local/bin/runner-entrypoint.sh"]
CMD ["node", "/app/runner.mjs"]
