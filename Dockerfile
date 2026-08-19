# syntax=docker/dockerfile:1
#
# An isolated container for running Claude Code against everything under
# ~/Projects, with network access to DDEV projects via ddev-router.
#
# Two images come out of this file:
#
#   base              everything that decides how code builds and renders
#   claudebox:latest  base + the agent            (the default build target)
#
# and a third out of runner/Dockerfile: claudebox-runner:latest, which is base
# plus a network service, for running tests on another machine. See the comment
# on the base stage for why the boundary is where it is.

# ---------------------------------------------------------------------------
# Ubuntu 24.04's font binaries, for screenshot testing.
#
# Matomo's UI baselines are rendered on ubuntu-24.04 runners. Debian and Ubuntu
# ship the same UPSTREAM font versions from different package revisions --
# fonts-dejavu-core 2.37-6 here against 2.37-8 there -- and the files are not
# byte-identical. Identical text then rasterises differently: same font, same
# metrics, same layout, every glyph a pixel off. That is precisely what a
# screenshot comparison fails on, and precisely what it looks like when you
# conclude the wrong font is being used. The font selection is fine; the hinting
# is not. Liberation differs between the two distros as well.
#
# So take the font binaries from the distro CI actually renders on.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS cifonts
RUN apt-get update && apt-get install -y --no-install-recommends \
        fontconfig \
        fonts-dejavu-core \
        fonts-liberation \
        fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# The phpantom language server, built here rather than downloaded.
#
# The phpantom plugin (entrypoint.sh installs it) ships a wrapper that fetches
# phpantom_lsp from GitHub Releases on first use. That artifact is linked
# against glibc 2.39 and the runtime image below is bookworm, which has 2.36, so
# the download succeeds and the binary then dies on a missing GLIBC_2.39 with no
# musl build published as an alternative. Building the same tag against this
# distro's glibc is the fix that leaves the runtime image's package set alone.
#
# The wrapper prefers a phpantom_lsp found on PATH over anything it would
# download, so the binary copied out of here is what runs; PHPANTOM_NO_DOWNLOAD
# below makes the fallback a clear error rather than a silent, unusable
# download. Bump PHPANTOM_LSP_VERSION to take a new release.
#
# The build reaches github.com twice: the source clone, and a phpstorm-stubs
# tarball that build.rs pins by commit and verifies against a SHA-256 in
# stubs.lock. Both are the host's network -- "claudebox rebuild" runs on the
# host daemon, not through the box's proxy -- so neither needs an allowlist
# entry.
#
# This costs about nine minutes, and "claudebox rebuild" passes --no-cache, so
# it is nine minutes on every rebuild rather than only the first. BuildKit cache
# mounts on the crate registry and the target directory are the usual answer and
# do nothing here: they come back empty on the next build on this host, and a
# second --no-cache build with them took the same 8m20s as the first. Left out
# rather than left in looking like an optimisation.
# ---------------------------------------------------------------------------
FROM rust:1-bookworm AS phpantom
ARG PHPANTOM_LSP_VERSION=0.9.0
RUN git clone --depth 1 --branch "${PHPANTOM_LSP_VERSION}" \
        https://github.com/PHPantom-dev/phpantom_lsp.git /src \
 && cd /src \
 && PHPANTOM_GIT_VERSION="${PHPANTOM_LSP_VERSION}" cargo build --release --locked \
 && strip target/release/phpantom_lsp

# ---------------------------------------------------------------------------
# base -- the environment the box and the remote runner share.
#
# Everything that decides how a test RENDERS or RUNS belongs in here: the fonts
# and the fontconfig rules that select them, Chromium's shared libraries, PHP
# and its extensions, node, composer, the docker CLI, and the ImageMagick limits
# a full-page screenshot comparison needs.
#
# claudebox:latest is this plus the agent. claudebox-runner:latest
# (runner/Dockerfile) is this plus a network service, built and run on another
# machine. That split is what makes screenshot-baseline parity between the two
# STRUCTURAL rather than a matter of keeping two package lists in step: they
# come off the same layers, and anything added past this stage boundary is by
# construction something a test cannot see.
#
# So the rule for editing below this point is: if a test could observe it, it
# goes above the boundary, not below.
# ---------------------------------------------------------------------------
FROM node:22-bookworm-slim AS base

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
        imagemagick \
        jq \
        less \
        nano \
        openssh-client \
        php-cli \
        php-curl \
        php-gd \
        php-mbstring \
        php-mysql \
        php-xml \
        php-zip \
        procps \
        python3 \
        ripgrep \
        rsync \
        socat \
        unzip \
        wget \
        zip \
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

# Shared libraries a headless Chromium needs, for Puppeteer-driven test suites
# (Matomo's tests/UI). The browser itself is NOT installed: Puppeteer downloads
# its own pinned build into the project's node_modules from
# storage.googleapis.com, which is on the allowlist. Only the runtime
# dependencies of that download are baked in here, plus one font family so text
# renders as glyphs rather than boxes.
#
# Chromium still needs --no-sandbox in this container (no user namespaces for it
# to drop into); Matomo already sets that in tests/UI/config.dist.js.
RUN apt-get update && apt-get install -y --no-install-recommends \
        fontconfig \
        fonts-dejavu-core \
        fonts-liberation \
        fonts-noto-color-emoji \
        libasound2 \
        libatk-bridge2.0-0 \
        libatk1.0-0 \
        libatspi2.0-0 \
        libcairo2 \
        libcups2 \
        libdbus-1-3 \
        libdrm2 \
        libexpat1 \
        libgbm1 \
        libglib2.0-0 \
        libgtk-3-0 \
        libnspr4 \
        libnss3 \
        libpango-1.0-0 \
        libpangocairo-1.0-0 \
        libx11-6 \
        libx11-xcb1 \
        libxcb1 \
        libxcomposite1 \
        libxdamage1 \
        libxext6 \
        libxfixes3 \
        libxi6 \
        libxkbcommon0 \
        libxrandr2 \
        libxrender1 \
        libxshmfence1 \
        libxss1 \
        libxtst6 \
    && rm -rf /var/lib/apt/lists/*

# The fonts Matomo's UI tests run against in CI.
#
# The baselines under tests/UI/expected-screenshots are produced by
# matomo-org/github-action-tests, whose prepare.sh copies these exact TTFs into
# $HOME/.fonts and runs fc-cache before the suite. Without them every screenshot
# assertion fails on glyph differences that no amount of retrying will settle.
#
# Taken from the same repo and ref the workflow pins (@main), rather than
# vendored here, so a rebuild tracks what CI is actually using -- and so a set of
# proprietary Microsoft fonts does not end up committed to this repo. The
# tradeoff is that a rebuild needs GitHub, and that CI changing these fonts
# changes the box's rendering too, which is the point.
#
# System-wide rather than ~/.fonts as CI does it: HOME is a volume that
# entrypoint.sh seeds only once, so a copy there would not survive a change.
RUN set -eux; \
    tmp="$(mktemp -d)"; \
    git clone --depth 1 https://github.com/matomo-org/github-action-tests.git "${tmp}"; \
    install -d /usr/local/share/fonts/matomo-ci; \
    cp "${tmp}"/artifacts/fonts/*.ttf /usr/local/share/fonts/matomo-ci/; \
    chmod 0644 /usr/local/share/fonts/matomo-ci/*.ttf; \
    rm -rf "${tmp}"; \
    fc-cache -f >/dev/null

# Ubuntu's builds of those same font packages, laid over Debian's, plus the two
# fontconfig rules Ubuntu enables and Debian does not:
#
#   10-sub-pixel-rgb            Ubuntu resolves rgba=rgb; Debian leaves it unset,
#                               and Chromium asks fontconfig for that setting.
#   70-no-bitmaps-except-emoji  Debian's 70-no-bitmaps rejects EVERY bitmap font,
#                               which silently discards Noto Color Emoji. Ubuntu
#                               keeps the emoji one.
#
# The Debian font packages stay installed so dpkg's dependency graph is intact;
# only the files they own are replaced. Ubuntu ships two DejaVu Mono obliques
# Debian does not, so this adds files rather than leaving stale ones behind.
COPY --from=cifonts /usr/share/fonts/truetype/dejavu/     /usr/share/fonts/truetype/dejavu/
COPY --from=cifonts /usr/share/fonts/truetype/liberation/ /usr/share/fonts/truetype/liberation/
COPY --from=cifonts /usr/share/fonts/truetype/noto/       /usr/share/fonts/truetype/noto/
COPY --from=cifonts /usr/share/fontconfig/conf.avail/70-no-bitmaps-except-emoji.conf \
                    /usr/share/fontconfig/conf.avail/70-no-bitmaps-except-emoji.conf
RUN set -eux; \
    rm -f /etc/fonts/conf.d/70-no-bitmaps.conf; \
    ln -sf /usr/share/fontconfig/conf.avail/10-sub-pixel-rgb.conf \
           /etc/fonts/conf.d/10-sub-pixel-rgb.conf; \
    ln -sf /usr/share/fontconfig/conf.avail/70-no-bitmaps-except-emoji.conf \
           /etc/fonts/conf.d/70-no-bitmaps-except-emoji.conf; \
    fc-cache -f >/dev/null

# ImageMagick's Debian defaults (256MiB memory, 16KP dimensions, 128MP area) are
# well below what comparing full-page screenshots needs. CI raises exactly these
# in prepare.sh, so match it. Note prepare.sh's last line has a typo -- it
# rewrites the "disk" policy's NAME to "area" -- which is clearly not intended;
# the disk limit is set properly here. These are resource ceilings only and
# cannot affect how anything renders.
RUN sed -i -E \
        -e 's/name="memory" value="[^"]+"/name="memory" value="2GiB"/' \
        -e 's/name="width" value="[^"]+"/name="width" value="64KP"/' \
        -e 's/name="height" value="[^"]+"/name="height" value="64KP"/' \
        -e 's/name="area" value="[^"]+"/name="area" value="1GiB"/' \
        -e 's/name="disk" value="[^"]+"/name="disk" value="4GiB"/' \
        /etc/ImageMagick-6/policy.xml

# The node image already owns uid/gid 1000. Replace that user with one matching
# the host user, so files written into the bind-mounted source tree keep the
# right ownership instead of coming out root-owned.
RUN userdel -r node >/dev/null 2>&1 || true; \
    groupadd -g "${GID}" "${USERNAME}"; \
    useradd -m -d "/home/${USERNAME}" -u "${UID}" -g "${GID}" -s /bin/bash "${USERNAME}"

ENV BOX_USER=${USERNAME}
ENV HOME=/home/${USERNAME}

# ---------------------------------------------------------------------------
# claudebox -- base plus the agent and the tooling only an agent needs.
#
# Nothing here may change how anything renders; see the note on the base stage.
# ---------------------------------------------------------------------------
FROM base AS claudebox

# Re-declared because ARGs do not cross a FROM. The values compose passes are
# applied to every stage that declares them, so these stay the same user.
ARG USERNAME=dizzy
ARG UID=1000
ARG GID=1000

RUN npm install -g @anthropic-ai/claude-code

# opencode, the box's second agent ("claudebox opencode"). The npm package is a
# thin launcher; the real program is a ~180MB Bun binary pulled in as a
# per-platform optional dependency (opencode-linux-x64), which is most of what
# this layer adds to the image.
#
# The image owns the version, so `claudebox rebuild` is how it moves --
# OPENCODE_DISABLE_AUTOUPDATE in docker-compose.yaml stops opencode replacing
# itself with a copy in the HOME volume that would then shadow this one and
# drift from what the Dockerfile says is installed.
#
# Being a Bun binary, it ignores NODE_OPTIONS -- so the DNS-preflight preload
# below does not apply to it. It does not need it: Bun's fetch reads
# HTTP_PROXY/HTTPS_PROXY/NO_PROXY on its own.
RUN npm install -g opencode-ai

# The language server behind the typescript-lsp plugin (entrypoint.sh installs
# it). That plugin is only a declaration -- it says to run
# `typescript-language-server --stdio` for .ts/.tsx/.js/.jsx and nothing more --
# so without these two packages on PATH it installs cleanly and then every LSP
# request fails. typescript comes along because the server is a wrapper around
# tsserver: it prefers a workspace's own typescript and needs some copy to fall
# back to when a project has no node_modules, which in this box is often the
# case before an install has been run.
#
# Here rather than left to the box to install at runtime, for the same reason
# opencode is: the image owns the version, and npm's registry is reachable at
# build time on the host's network but only through the allowlist afterwards.
RUN npm install -g typescript-language-server typescript

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

# Prepares a DDEV project's web container to behave like the single-host CI
# runner Matomo's UI-test baselines came from: client IP and path alias. Both
# live in that container's filesystem and are discarded by `ddev restart`, so
# this has to be re-runnable -- the launcher calls it on every run, and the
# box's Claude can call it after a mid-session restart. See CLAUDEBOX.md.
COPY ddev-fixups /usr/local/bin/claudebox-ddev-fixups
COPY ddev-realip.conf /usr/local/share/claudebox/ddev-realip.conf
RUN chmod 0755 /usr/local/bin/claudebox-ddev-fixups \
 && chmod 0644 /usr/local/share/claudebox/ddev-realip.conf

# `runner` in the box pushes a project's source to the test runner on the other
# machine and runs commands there, forwarding to runner-relay over the internal
# network. Baked in for the same reason the ddev shim is: it must always be on
# PATH, and a bind-mounted single file goes stale in the container.
COPY runner-shim /usr/local/bin/runner
RUN chmod 0755 /usr/local/bin/runner

# Deletes gitignored build output from the workspace, which matters when the
# workspace is a removable drive carrying source between machines. In here
# rather than only on the host because the box is where the tree is worked on:
# the agent can strip and reinstall in one place, and "claudebox strip" on the
# host is a wrapper around this same script. See strip-artifacts for the
# gitignore rule that keeps it from deleting a committed vendor/.
COPY strip-artifacts /usr/local/bin/claudebox-strip-artifacts
RUN chmod 0755 /usr/local/bin/claudebox-strip-artifacts

# Claude Code's managed-policy memory location on Linux. Loaded at the start of
# every session in every directory in the box, and not excludable by settings --
# so the box's Claude always knows it is in a container, that egress is
# allowlisted, and what its opaque proxy errors actually mean.
#
# Baked in rather than written to ~/.claude/CLAUDE.md: HOME is a persistent
# volume that entrypoint.sh seeds only once, so a copy there would never pick up
# edits. Rebuild after changing box-CLAUDE.md.
COPY box-CLAUDE.md /etc/claude-code/CLAUDE.md

# The same notes for opencode, which has no managed-policy path of its own. The
# baked config adds this file to every session's instructions; OPENCODE_CONFIG
# (docker-compose.yaml) points opencode at it. That variable names an ADDITIONAL
# config, not a replacement, so a ~/.config/opencode/opencode.json seeded from
# the host still loads alongside it.
#
# One source file for both agents on purpose: everything in it is about the box,
# not about who is reading it, and two copies would drift.
COPY box-CLAUDE.md    /etc/claudebox/AGENTS.md
COPY box-opencode.json /etc/claudebox/opencode.json

# The language server built in the phpantom stage at the top of this file. On
# PATH, which is where the plugin's wrapper looks before it considers a
# download; PHPANTOM_NO_DOWNLOAD turns the remaining fallback into an error,
# since the only thing it could fetch is a binary this glibc cannot run.
COPY --from=phpantom /src/target/release/phpantom_lsp /usr/local/bin/phpantom_lsp
ENV PHPANTOM_NO_DOWNLOAD=1

RUN chmod 0644 /etc/claude-code/CLAUDE.md \
               /etc/claudebox/AGENTS.md \
               /etc/claudebox/opencode.json

# Node has its own CA bundle and ignores the system store, so point it at the
# DDEV root CA that entrypoint.sh installs.
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/ddev-rootCA.crt

WORKDIR /home/${USERNAME}/Projects

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
