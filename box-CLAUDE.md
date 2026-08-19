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

## Running tests on another machine (`runner`)

There may be a second machine on the LAN set up as a **runner** — the same
image's base layers with no agent in it, for running heavy suites (Matomo's UI
tests above all) somewhere with more CPU. `runner status` says whether one is
joined; if it answers with the join instructions instead, there is none and this
whole section does not apply.

```
runner status          what is joined, and which project/workdir this resolves to
runner sync            push this project's source there
runner run <cmd...>    sync, then run <cmd> there, in this same relative directory
runner exec <cmd...>   run <cmd> there WITHOUT syncing first
```

`runner run` is the one to use. Output streams back as it happens and the exit
code is the remote command's, so it behaves like running it here.

What crosses the network is **source only**. A directory is left behind exactly
when the project's git ignores it — so `vendor/`, `node_modules/`, a gitignored
`wp/` holding a whole WordPress install, and `.ddev/`'s generated directories
all stay on the runner side, while a *committed* `vendor/` (some WordPress
plugins) still goes. Nothing is decided by directory name.

That same list is why the runner accumulates its own build: those paths are
invisible to the sync, so nothing there is ever deleted by it. The first thing
to do with a new project on the runner is therefore install into it —
`runner exec "composer install"`, `npm ci`, `ddev wp-matomo:install` — once.

Two consequences worth remembering:

- Anything a test WRITES on the runner stays there until you ask for it. A suite
  whose result is a file — screenshot diffs, coverage — is not finished by
  running it remotely; `runner fetch <path>` brings it back.
- The runner has ordinary internet access; it is not behind this box's
  allowlist. A `composer install` that fails here may well work there.

### DDEV on the runner

The runner has a **real `ddev`**, not the shim you have here, driving its own
private Docker daemon. So a DDEV-backed suite runs there in one command:

```
runner run "ddev start -y && claudebox-ddev-bridge && ddev <the project's test command>"
```

`claudebox-ddev-bridge` is the runner's counterpart to what the launcher does
for you on this side. It points `db:3306` at the project's database and makes
`https://<project>.ddev.site` resolve to the project rather than to the runner
itself. Run it after every `ddev start` and after a runner restart; it is
idempotent, and `claudebox-ddev-bridge --status` shows what is pointed where.

`claudebox-ddev-fixups` is there too and behaves exactly as it does here.

After `claudebox-ddev-bridge`, three addresses mean on the runner what they mean
on a single-host CI runner — which is what the screenshot baselines were recorded
against:

| | |
|---|---|
| `http://host.docker.internal/` | the bridged DDEV project, with the client presented as **127.0.0.1**. This is what wp-env's WordPress and the UI specs navigate to. |
| `https://<project>.ddev.site/` | the same project through ddev-router, client IP not rewritten |
| `localhost:8888`, `localhost:8889` | wp-env's WordPress, forwarded from the runner's own dind |

Anything a run produces stays on the runner unless you ask for it:

```
runner fetch tests/UI/screenshot-diffs      copy a path back into this tree
```

It takes a path because there is no general answer to "what is an artifact" —
name what you want. It extracts over what is here and deletes nothing.

One real difference from a DDEV project on this machine, worth knowing before it
confuses you: **the runner's DDEV containers run as root inside**. That is DDEV's
own behaviour on a rootless Docker daemon — container root maps to the unprivileged
user outside, so it is safe, and file ownership in the tree comes out the same.
What it changes is tools that refuse to be root. The one you will meet is
wp-cli:

```
If you'd like to continue as root, please run this again, adding this flag: --allow-root
```

That is not a broken runner and not something to fix by changing permissions;
the command needs `--allow-root` when it runs there.

Reaching it goes through `runner-relay` on the internal network, which is the
only thing that holds its address, its token and its certificate. This box has
no route to that machine and no credential for it, so `curl` to the runner will
not work and is not meant to.

## Installed tools

git, ripgrep, jq, curl, wget, less, nano, rsync, zip/unzip, php-cli 8.2 (curl,
gd, mbstring, mysql, xml, zip), composer, node 22, docker CLI + buildx + compose,
imagemagick (`compare`/`identify`, which screenshot assertions need).

Everything in that list, the fonts below and the ImageMagick limits come from a
`base` stage the remote runner's image is also built from, so a test renders the
same in both places. That is why they are the same list and not two lists.

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
