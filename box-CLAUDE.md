# You are running inside claudebox

A container that holds every project under `~/Projects`. It runs one of two
agents — Claude Code (`claudebox`) or opencode (`claudebox opencode`) — and
everything below is about the box, so it applies whichever one you are.

This file is baked into the image twice: at `/etc/claude-code/CLAUDE.md`, Claude
Code's managed-policy path, and at `/etc/claudebox/AGENTS.md`, which opencode is
pointed at by a baked config. Edit it in `~/.claudebox/box-CLAUDE.md` on the host
and run `claudebox rebuild`.

## Filesystem

- `~/Projects` is the host's source tree, bind-mounted. Normally it is the same
  absolute path on the host, so paths you report are directly clickable outside
  the box. It can be configured to a different host directory — an external
  drive, say — and then it is not: `$CLAUDEBOX_WORKSPACE` is the tree's path in
  here and `$CLAUDEBOX_WORKSPACE_HOST` the host directory behind it. When those
  two differ, translate the prefix before naming a path the host has to act on,
  and say which side you mean.
- `/media` is **not** the host's drives. It is `~/.claudebox/media` on the host,
  **read-only**: material staged there deliberately with `claudebox media add`.
  Read from it freely; writes fail. If something expected is missing, the answer
  is "ask the host to stage it" — say that rather than reporting an empty
  directory, and never suggest mounting the drive itself. Staging exists so
  drives can be ejected while the box runs; a bind of the real `/media` pins
  them until Docker Desktop is quit.
- `claudebox-strip-artifacts` deletes gitignored build output (`node_modules`,
  `vendor`, `target`, …) from the workspace, asking first. Reach for it when the
  workspace is short of space — `df ~/Projects` — or before the host ejects a
  removable workspace, since that drive should carry source, not artifacts that
  are machine-specific anyway. It never touches a directory the project does not
  ignore, so a committed `vendor/` is safe; `--dry-run` reports without deleting.
  Reinstalling afterwards is yours to do (`npm ci`, `composer install`, …).
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

## Running Matomo's UI tests against a DDEV project

Two settings inside the project's **web container** make it behave like the
single-host CI runner the expected screenshots came from: Apache takes the
client IP from `X-Real-IP`, and the box's absolute project path resolves there
so Matomo's symlinks in `tests/PHPUnit/proxy/` are not left dangling.

The launcher applies both when it starts a session. They live in that
container's filesystem, so **`ddev restart` throws them away** — and nothing
warns you, because the tests keep running and simply produce wrong pixels:

| Symptom | What it means |
|---|---|
| Visits-log screenshots differ only in the IP text (not `127.0.0.1`) | the client-IP setting is gone |
| `matomo.js` 404s, visits log empty, icons broken across reports | the path alias is gone |

```
cd <project> && claudebox-ddev-fixups --check   # report
cd <project> && claudebox-ddev-fixups           # apply what is missing
```

Run the check **before regenerating any screenshot baseline** — with either
setting missing the run still succeeds and bakes the wrong pixels in, which is
worse than a failure because it looks finished. Applying is idempotent.

One DDEV project's database is reachable as `db:3306` — the same name its own
web container uses, so a project's existing config works here unchanged. Which
project is bridged is fixed by the host launcher and printed when it starts; if
`db` does not resolve, no project was bridged and that is the user's call, not
something to work around.

## Docker

`docker` here drives a private rootless daemon (`DOCKER_HOST=tcp://dind:2375`).
Build and run whatever you like in it. The host's daemon, its containers, its
images and its DDEV projects are invisible on purpose — that isolation is the
point, so don't treat their absence as a misconfiguration to fix.

Containers you start inherit the proxy automatically (`docker run` and `docker
compose` both), so they reach the same allowlist you do — including
`http://<project>.ddev.site`. Two things follow. They cannot do `https://` to a
DDEV site, because only this box trusts the mkcert CA; use `http://`. And HTTP
from one nested container to another by service name goes to the proxy and is
refused — set `no_proxy` for those names in the stack itself.

A nested container's published ports are reachable here as `dind:<port>`. Ports
listed in `CLAUDEBOX_DIND_PORTS` (wp-env's 8888/8889 by default) are also
forwarded onto this container's own `localhost:<port>`, so both spellings work;
other ports are only at `dind:<port>` until that list is changed on the host.

`host.docker.internal` reaches the bridged DDEV project — from nested containers
and from here alike, so Chromium can load its tracker from the same URL CI uses.
It is one fixed destination, not a general forwarder; it cannot reach anything
else, and it is not a way around the allowlist.

The proxy only speaks `CONNECT`, so an HTTPS client has to be able to tunnel.
Two common ones cannot, and both look like a blocked domain:

- **busybox `wget`** (most alpine images) — sends the whole URL in a plain
  request and gets a `403`. Use `curl`, or `apk add wget`.
- **PHP stream wrappers** (`file_get_contents('https://…')`) — ignore the proxy
  variables. Pass `stream_context_create(['http' => ['proxy' => 'tcp://<proxy>']])`,
  or use the curl extension, which works on its own.

`claudebox denied` distinguishes the two cases: `CONNECT host:443` is a real
allowlist refusal, `GET https://...` is a client that cannot tunnel — asking for
that domain to be allowed will not help.

## DDEV

`ddev` is a shim, not the real CLI. It supports only `ddev exec [-s <service>]
<cmd...>` plus shorthands (`ddev composer|npm|php|wp|...`), forwarded to a scoped
relay against an already-running project. Starting, stopping and reconfiguring
projects is the user's job on the host; ask rather than trying to do it.

## Installed tools

git, ripgrep, jq, curl, wget, less, nano, rsync, zip/unzip, php-cli 8.2 (curl,
gd, mbstring, mysql, xml, zip), composer, node 22, docker CLI + buildx + compose,
imagemagick (`compare`/`identify`, which screenshot assertions need).

Fonts are matched to Matomo's `ubuntu-24.04` CI runners on purpose — the DejaVu,
Liberation and Noto binaries come from `ubuntu:24.04` rather than Debian, whose
builds of the same versions rasterise differently, and Arial/Verdana/Courier New
come from the CI action. Don't "fix" a screenshot diff by installing more fonts;
check first whether word positions match, which means the font is right and only
its rendering differs.

Headless Chromium's shared libraries are installed, so a Puppeteer browser
downloaded into a project's `node_modules` runs here. There is no browser in the
image itself, and Chromium needs `--no-sandbox` in this container.

Debian and npm mirrors are allowlisted, so `apt-get install` and `npm i -g` do
work — but the image is rebuilt from the Dockerfile and anything you install this
way is lost. For a tool that should stick around, ask the user to add it to
`~/.claudebox/Dockerfile` and rebuild.
