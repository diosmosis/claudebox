# You are running inside claudebox

A container that holds every project under `~/Projects`. This file is baked into
the image at `/etc/claude-code/CLAUDE.md`; edit it in `~/.claudebox/box-CLAUDE.md`
on the host and run `claudebox rebuild`.

## Filesystem

- `~/Projects` is the host's source tree, bind-mounted at the same absolute path
  it has on the host. Paths you report are directly clickable outside the box.
- Nothing else of the host is visible. `~` is a container-private volume.
- Plans written to `~/.claude/plans` land in `~/.claudebox/plans` on the host.

## Network: default-deny egress

There is no route off the internal network. Everything outbound goes through a
Squid proxy that refuses any host not on the allowlist.

**A refused host does not look like a refusal. Learn these two signatures:**

| What you see | What it means |
|---|---|
| `curl: (56) CONNECT tunnel failed, response 403` | not on the allowlist |
| node `fetch failed` / `Request was cancelled` | not on the allowlist |
| `EAI_AGAIN`, `Could not resolve host` | also the proxy — the box has no resolver of its own |

None of these mean the network is down, and none are worth retrying. Read
`/etc/claudebox/allowlist.conf` (mounted read-only) to see what is permitted;
`*.example.com` entries cover subdomains, a leading `.example.com` covers the
domain and its subdomains.

You cannot change the allowlist from in here. If a host you need is missing, stop
and ask the user to run `claudebox allow <domain>` on the host — it hot-reloads,
no rebuild. Never route around the proxy or disable TLS verification to "make it
work"; that is the isolation boundary, not an obstacle.

DDEV projects are reachable at `https://<project>.ddev.site` and the mkcert root
CA is already trusted, so certificates validate.

## Docker

`docker` here drives a private rootless daemon (`DOCKER_HOST=tcp://dind:2375`).
Build and run whatever you like in it. The host's daemon, its containers, its
images and its DDEV projects are invisible on purpose — that isolation is the
point, so don't treat their absence as a misconfiguration to fix.

## DDEV

`ddev` is a shim, not the real CLI. It supports only `ddev exec [-s <service>]
<cmd...>` plus shorthands (`ddev composer|npm|php|wp|...`), forwarded to a scoped
relay against an already-running project. Starting, stopping and reconfiguring
projects is the user's job on the host; ask rather than trying to do it.

## Installed tools

git, ripgrep, jq, curl, wget, less, nano, rsync, zip/unzip, php-cli 8.2 (curl,
mbstring, xml, zip), composer, node 22, docker CLI + buildx + compose.

Debian and npm mirrors are allowlisted, so `apt-get install` and `npm i -g` do
work — but the image is rebuilt from the Dockerfile and anything you install this
way is lost. For a tool that should stick around, ask the user to add it to
`~/.claudebox/Dockerfile` and rebuild.
