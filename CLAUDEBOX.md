# claudebox

Context for Claude. Read this before modifying anything in `~/.claudebox/`.

## Purpose

Run Claude Code against every project under `~/Projects` from a single isolated
container, instead of installing it per-project or on the host.

Three requirements drove the design, in order:

1. **One box, not one per project.** `~/Projects` is the root for all work.
2. **Isolation.** Claude runs in its own container; the host filesystem is not
   exposed beyond the shared source tree.
3. **Reachability.** The box must be able to load DDEV project URLs
   (`https://<project>.ddev.site`) as if it were the host.

Later additions, in the order they were asked for:

4. **Its own Docker daemon**, so Claude can start containers (e.g. testing code
   under a different PHP version) without touching host Docker.
5. **Default-deny egress** with a domain allowlist, so the box cannot reach the
   internet except where explicitly permitted.

Explicit non-goal: **the box does not control DDEV's lifecycle.** No host Docker
socket in the box; the user starts and stops projects on the host. Claude can
reach running projects over HTTP, run its own throwaway containers, and — through
a narrow, scoped relay — `ddev exec` into a running project's containers (e.g. to
build assets). It still cannot start, stop, or reconfigure projects, or touch the
host daemon. See *ddev exec via a scoped relay* and *Why no ddev CLI* below.

## Architecture

```
                    claudebox_inner  (internal: true)
                    ┌───────────────────────────────────────────────────────────────┐
                    │  claudebox   claudebox-dind   ddev-relay   ddev-db  ddev-http  │
                    │      │             │              │           │          │     │
                    │      └─── proxy ───┘              │           │          │     │
                    └───────────│───────────────────────┼───────────┼──────────┼────┘
                                │       host docker.sock ┘ → docker exec
                                │                            ddev-<project>-<svc>
                                ├── claudebox_edge ──→ internet (allowlist)
                                └── ddev_default ────→ ddev-router
                                                            │
                    ddev-db  ─── ddev_default ───────────────→ ddev-<project>-db:3306
                    ddev-http ── ddev_default ───────────────→ ddev-<project>-web:80
                                                                (Host + client IP rewritten;
                                                                 NOT via ddev-router, which
                                                                 would overwrite the latter.
                                                                 Reached as
                                                                 host.docker.internal, both
                                                                 in dind and in the box)
```

| Container | Image | Role |
|---|---|---|
| `claudebox` | built from `Dockerfile` | Where Claude Code runs. No route off `claudebox_inner`. |
| `claudebox-proxy` | built from `proxy/Dockerfile` | Squid forward proxy. The only container with egress. Also the only one that can reach `ddev-router`. |
| `claudebox-dind` | `docker:dind-rootless` | Private rootless Docker daemon on `tcp://dind:2375`. |
| `claudebox-ddev-relay` | built from `ddev-relay/Dockerfile` | Holds the host Docker socket; runs `ddev exec` in DDEV containers on the box's behalf. On `inner` only — no egress. See below. |
| `claudebox-ddev-db` | `alpine/socat` | One fixed TCP forward: `db:3306` on `inner` → `ddev-<project>-db:3306` on `ddev_default`. Lets PHP in the box use a DDEV project's database. See below. |
| `claudebox-ddev-http` | built from `ddev-http/Dockerfile` | nginx on a fixed address: sets `Host` to the project's hostname, presents the client as `127.0.0.1`, and proxies to the project's web container. This is what `host.docker.internal` resolves to, in dind and in the box. See below. |

| Network | Kind | Members |
|---|---|---|
| `claudebox_inner` | `internal: true` | claudebox, dind, proxy, ddev-relay, ddev-db, ddev-http (`10.99.1.10`) |
| `claudebox_edge` | bridge | proxy only |
| `ddev_default` | external (DDEV's) | proxy, ddev-db, ddev-http |

| Volume | Contents |
|---|---|
| `claudebox-home` | Container `$HOME` (`/home/dizzy`), including its own `~/.claude` — except `~/.claude/plans`, which is a host bind (see below) |
| `claudebox-dind-data` | dind's image store — separate from the host's |

### Load-bearing decisions

Each of these is doing real work. Changing one breaks something specific.

- **`claudebox_inner` is `internal: true`.** Docker installs no default route and
  no NAT, so the box has no way out and no external DNS. This — not the
  `HTTPS_PROXY` env var — is what enforces deny-by-default. The env vars only
  tell well-behaved clients where the exit is; anything ignoring them fails to
  connect rather than escaping. Verified: `curl --noproxy '*'` to an *allowed*
  host still fails, as does a raw-IP connect and any external DNS lookup.

- **`~/Projects` is mounted at its host path inside the container** (not
  `/workspace`), so paths Claude prints are clickable on the host and
  `claudebox` from a subdirectory lands in the matching directory.

- **The workspace is also mounted into `dind` at the same path.** `-v` sources in
  a nested `docker run` are resolved by the *daemon*, not the client. Without
  this second mount, `-v /home/dizzy/Projects/x:/app` silently creates an empty
  directory instead of mounting the source.

- **`$HOME` is a named volume with the bind mount nested inside it.** Docker
  orders mounts by path depth, so the volume lands on `/home/dizzy` first and
  the bind on `/home/dizzy/Projects` on top. Nothing else from the host home
  directory is exposed — no SSH keys, no cloud credentials.

- **The box's user is rebuilt at uid/gid 1000** to match the host user. The
  `node:22` base image already owns uid 1000, so `entrypoint`-adjacent Dockerfile
  logic does `userdel -r node` first. Files written into the mount come out
  `dizzy:dizzy`, not root-owned. This also lets
  `--dangerously-skip-permissions` run, which refuses as root.

- **DDEV hostnames are written into the PROXY's `/etc/hosts`, not the box's.**
  `*.ddev.site` resolves to `127.0.0.1` in public DNS, which inside a container
  is the container itself. Since the box has no resolver, it sends
  `CONNECT matomo.ddev.site:443` and the *proxy* is what must resolve the name.
  The launcher rewrites those entries on every run from `ddev list -j`.

- **The proxy joins `ddev_default` and talks to `ddev-router` directly**, rather
  than reaching DDEV via published host ports. Global DDEV config has
  `router_bind_all_interfaces: false`, so 80/443 are bound to host loopback only
  and are unreachable from any container.

- **Squid tunnels HTTPS with `CONNECT` and never intercepts it.** No MITM CA is
  involved, so end-to-end TLS is untouched and DDEV's mkcert certificates still
  validate inside the box. The corollary is that an HTTPS client must be able to
  issue `CONNECT`; one that cannot is refused rather than accommodated, since
  accommodating it means decrypting. See *What can and cannot use the proxy*.

- **`ddev exec` works in the box via a scoped relay, not host-daemon access.**
  The box has no `ddev` and no host Docker daemon (its `docker` is dind), so it
  cannot reach the host's DDEV containers directly — by design, since host-daemon
  access is root-equivalent and would end the jail. Instead, `claudebox-ddev-relay`
  holds the host socket and exposes exactly one operation on the internal network:
  given `{workdir, service, command}`, run `docker exec -w <mapped> ddev-<project>-<service>
  bash -lc <command>` — but only for a `<project>` whose `.ddev/config.yaml` sits
  under the workspace and whose container carries that project's own
  `com.ddev.site-name` label. The box speaks only to the relay's HTTP endpoint;
  it never touches the socket. So a compromised box gains nothing beyond running
  commands in a web container its own mounted source already drives — it cannot
  `docker run -v /:/host`, exec into `ddev-router`/another project, or reach the
  daemon. The relay is spawned with an argv array (no host shell), so the command
  string is only ever a shell *inside* the container. The residual trust is the
  relay's own ~200 lines: keep it small and allowlist-driven. The box side is a
  `ddev` shim baked into the image; it forwards `ddev exec` (and `composer`/`npm`/
  … shorthands) and points everything else back at the host.

- **A DDEV project's database is reachable in the box as `db:3306`, via one
  fixed forward.** `claudebox-ddev-db` is a socat sitting on both `inner` and
  `ddev_default`, aliased `db` on `inner`. The alias is the whole trick: Matomo's
  `config.ini.php` already says `host = "db"`, which is how the project's own web
  container reaches it too, so one config file works on both sides with nothing
  to switch and no test-only variant to maintain.

  It exists because a Matomo UI-test fixture is one PHP process that needs the
  database *and* Docker at once — it seeds the database directly, then shells out
  to wp-env to start containers. The web container has the database but no
  Docker; the box has Docker but no route to the database. Running that PHP
  inside DDEV through the relay cannot work, because wp-env would then have no
  daemon to start anything on.

  It grants the box nothing new — `ddev exec -s db` through the relay already
  runs arbitrary commands in that container. What keeps it narrow is that socat
  has one hard-coded destination. It is a single forward, not a general TCP
  proxy; making it general would be a hole straight through the allowlist, since
  `ddev_default` has real egress. Keep the destination fixed.

  Which project it points at comes from `BOX_DDEV_PROJECT`. The launcher
  auto-detects it when exactly one project is running and otherwise leaves it
  `none`, which resolves to nothing — with several projects up there is no
  defensible guess, and quietly bridging the wrong database is worse than
  bridging none.

- **`~/.claude/plans` is bind-mounted out to `~/.claudebox/plans` on the host.**
  The box writes plan-mode output to `~/.claude/plans`, which otherwise lives on
  the private `claudebox-home` volume and is invisible to the host. The launcher
  nests a bind on that one subpath (deeper than the volume, so it wins) into the
  generated override, and `mkdir`s the host side first so Docker doesn't create
  it root-owned. The rest of `~/.claude` stays on the volume; plans are the one
  part shared out, so they can be read and edited on the host. The host side sits
  in `~/.claudebox/` rather than the host's own `~/.claude`, keeping box state out
  of it.

- **`~/.claudebox/` lives outside `~/Projects` deliberately** — the box has
  read-write access to the whole workspace, so keeping its own configuration out
  of the mount means Claude-in-the-box cannot edit its own jail.

- **dind runs with no `--privileged`.** The minimum that works is
  `seccomp=unconfined`, `apparmor=unconfined`, `systempaths=unconfined`, plus
  `/dev/fuse` and `/dev/net/tun`. `systempaths=unconfined` is the non-obvious
  one: Docker masks parts of `/proc` by default, and the kernel then refuses
  `mount -t proc` inside the nested user namespace. Without it, nested
  containers fail with `error mounting "proc" ... operation not permitted`.

- **Nested containers are handed the proxy by the Docker client, not by the
  person running the command.** `entrypoint.sh` writes a `proxies.default` block
  into the box's `~/.docker/config.json`, and the Docker CLI injects those
  variables into every container it creates — `docker run` and `docker compose
  up` alike. That second one is the point: wp-env drives Compose, and no flag
  could have been threaded through it. The proxy's *address* has to be used
  rather than its name, because dind's embedded DNS knows nothing about
  `claudebox_inner`. Rewritten on every start, since that address changes with
  every recreation of the proxy container. Nothing is widened: those containers
  land on the same allowlist, and a denied host is still denied.

- **Two small forwarders make the box's URLs match a single-host CI runner's.**
  Screenshot baselines bake URLs into the pixels, so a suite whose baselines
  were generated on a runner only compares if the same names work here. Two
  structural gaps had to close, and both are naming, not reachability — the box
  could already reach everything involved:

  - *`localhost:<port>` for ports published inside dind.* A nested container
    publishes onto **dind's** interface, so wp-env's WordPress is at `dind:8888`
    and nothing expecting `localhost:8888` finds it. `entrypoint.sh` runs a
    loopback-bound socat per port in `CLAUDEBOX_DIND_PORTS` (8888/8889, wp-env's
    development and tests ports). Bound to `127.0.0.1` deliberately: it is a
    convenience for processes in the box, not a service for the network.
  - *`host.docker.internal`, at both levels.* wp-env attaches
    `host.docker.internal:host-gateway` to everything it starts, and Matomo's UI
    tests use that name to reach Matomo from inside WordPress. On a runner it
    lands on the host; here there is no such host, and dind's real gateway has
    nothing listening. dind is given `--host-gateway-ip=10.99.1.10`, the fixed
    address of `ddev-http`, which rewrites `Host` to the project's own hostname —
    the only thing `ddev-router` routes on — and proxies to it.

    `ddev-http` proxies to the project's **web container**, not to
    `ddev-router`, and presents the client as `127.0.0.1`. Both halves of that
    are load-bearing. On a single-host runner the browser and Matomo share a
    host, so every visit is recorded from `127.0.0.1`, and that address is baked
    into the baselines. Going through `ddev-router` cannot reproduce it: traefik
    *replaces* `X-Forwarded-For` with the peer it received the connection from
    unless that peer is in its trusted list, so anything nginx sets is discarded
    and Matomo records this container's address instead. Talking to the web
    container directly leaves the header ours. Verified by tracking a real hit
    through it and reading `log_visit.location_ip` back: `127.0.0.1`.

    The box needs the same name for itself, which is easy to miss because the
    nested half looks like the whole problem. Chromium runs *in the box* and
    loads Matomo's tracker from that URL, so without it the JS pageviews never
    fire and a visits-log screenshot comes out with one action instead of five.
    `ddev-http` therefore carries `host.docker.internal` as a network alias on
    `inner` (an alias, not `extra_hosts` on the box, so the address stays
    declared once), and the name is in the box's own `NO_PROXY`.

  Neither widens anything. Nested containers could already reach that network
  and that project through the proxy; these only put them at the addresses CI's
  URLs assume. Verified afterwards that a nested container which can reach
  `host.docker.internal` still cannot reach `example.com`. Keep `ddev-http`
  pointed at one fixed destination for the same reason as `ddev-db`: a forwarder
  that took its target from the request would be an open relay onto
  `ddev_default`, which unlike `claudebox_inner` has real egress.

- **`claudebox_inner` has a pinned subnet outside Docker's default address
  pool** (`10.99.1.0/24`). dockerd inside dind allocates bridges for nested
  containers from the same `172.16.0.0/12` pool the host daemon used for this
  network, and the two collide by chance — after which dind's own route for that
  range wins over its default route and the proxy becomes unreachable *from
  inside dind only*. See the trap below. dind also gets
  `--default-address-pool=base=172.28.0.0/14,size=24` so its allocations stay in
  a known band. Any replacement subnet has to be clear of `172.16.0.0/12`,
  `192.168.0.0/16` and the host LAN.

## Technologies

| Component | Version at build | Notes |
|---|---|---|
| Base image | `node:22-bookworm-slim` | node 22.23.1 |
| Claude Code | 2.1.218 | installed via `npm i -g @anthropic-ai/claude-code` |
| Proxy | Squid 5.7 on `debian:bookworm-slim` | |
| Nested daemon | `docker:dind-rootless` | server 29.6.2 |
| Host Docker | Docker Desktop on Linux, 29.6.2 | socket at `~/.docker/desktop/docker.sock` |
| DDEV | v1.25.3 | `performance_mode: none`, so plain bind mounts |
| Also in the box | git, ripgrep, jq, curl, php-cli 8.2 (incl. `mysqli`/`pdo_mysql`, `gd`), composer, docker CLI + compose plugin, headless-Chromium shared libs, imagemagick (`compare`/`identify`, for screenshot assertions) | ImageMagick's resource limits are raised to CI's values |
| Fonts | DejaVu / Liberation / Noto Color Emoji taken from `ubuntu:24.04`, plus CI's Arial, Verdana and Courier New | matched to the `ubuntu-24.04` runners so screenshot baselines compare; see the traps |

## Files

| Path | Purpose |
|---|---|
| `docker-compose.yaml` | The six services, three networks, two volumes |
| `Dockerfile` | The claudebox image |
| `entrypoint.sh` | Runs as root at start: installs the mkcert CA, seeds `~/.claude`, signals readiness |
| `ddev-shim` | The box's `ddev` (baked to `/usr/local/bin/ddev`); forwards `ddev exec` to the relay |
| `ddev-relay/Dockerfile`, `ddev-relay/relay.mjs` | The scoped `ddev exec` relay image and server |
| `ddev-http/Dockerfile`, `ddev-http/default.conf.template` | The `host.docker.internal` front door for nested containers |
| `ddev-fixups`, `ddev-realip.conf` | Baked in as `claudebox-ddev-fixups`; prepares a DDEV web container for UI tests (client IP, path alias) |
| `node-proxy-bootstrap.cjs` | Preloaded into every Node process via `NODE_OPTIONS`; DNS-preflight shim |
| `box-CLAUDE.md` | Baked to `/etc/claude-code/CLAUDE.md`; what the box's Claude is told about its own environment |
| `proxy/Dockerfile` | Squid image |
| `proxy/squid.conf` | Baked-in proxy policy |
| `proxy/allowlist.sh` | Expands `allowlist.conf` into Squid's ACL files; installed as `allowlist` |
| `allowlist.conf` | **Bind-mounted, user-editable.** The egress allowlist. Also mounted read-only into the box at `/etc/claudebox/allowlist.conf` so Claude can see what is permitted before guessing |
| `claudebox` | Host launcher, symlinked into `~/.local/bin` |
| `docker-compose.override.yaml` | Generated by the launcher; the `~/.claude/plans` bind plus any optional host mounts that exist |
| `plans/` | Host side of the `~/.claude/plans` bind — plans written in the box, readable here |

### Launcher commands

```
claudebox                  interactive session in the current directory
claudebox -p '...'         flags/prompt passed straight to claude
claudebox shell            bash in the box
claudebox rebuild          rebuild images (needed after Dockerfile/entrypoint edits)
claudebox stop             stop the stack (volumes survive)
claudebox allow <domain>   append to the allowlist and hot-reload the proxy
                           quote wildcards: claudebox allow '*.example.com'
claudebox reload           re-apply allowlist.conf after editing it by hand
claudebox allowed          show the allowlist
claudebox denied           show what the proxy has blocked
```

Env overrides: `BOX_WORKSPACE`, `BOX_USER`, `BOX_HOST_HOME`, `BOX_MKCERT_CA`,
`BOX_DDEV_PROJECT`.

### What the launcher does on each run

1. Creates `ddev_default` if absent (DDEV reuses it as-is).
2. Regenerates `docker-compose.override.yaml`: always the `~/.claudebox/plans →
   ~/.claude/plans` bind (after `mkdir`ing the host side), plus optional host
   mounts that actually exist (currently just `~/.gitconfig`) — binding a missing
   path would make Docker create a directory in the host home directory.
3. `compose up -d`, then **polls for `/run/claudebox.ready`** (see race below).
4. Checks the proxy's copy of `allowlist.conf` against the host's and remounts
   it (restart + re-expand) if they differ.
5. Resolves `ddev-router`'s IP and rewrites the proxy's `/etc/hosts`.
6. Injects `CLAUDEBOX_PROXY=http://<proxy-ip>:3128` into the exec environment.
7. `docker exec`s in as uid/gid 1000, mapping the host cwd 1:1.

## Egress allowlist

`allowlist.conf` is bind-mounted, so edits need a reload rather than a rebuild —
with the stale-mount caveat below, which the launcher now handles for you.
`#` comments are supported. Four entry forms:

| Entry | Matches |
|---|---|
| `example.com` | that host exactly |
| `.example.com` | the domain and every subdomain (Squid's own syntax) |
| `*.example.com` | the same thing, spelled the way people expect |
| `api-*.example.com` | `*` inside a label, matching within that label only |

Squid's `dstdomain` ACL has **no** wildcard syntax of its own — it reads
`*.example.com` as a literal hostname, matches nothing, and reports no error.
So `proxy/allowlist.sh` expands this file into the two files Squid actually
reads, at container start and on every reload:

- `/etc/squid/allowlist.domains` — `dstdomain` values; `*.x` becomes `.x`
- `/etc/squid/allowlist.regex` — anchored `dstdom_regex` values for the rest

Both are generated; editing them directly is pointless. Outside a leading `*.`,
a `*` matches within one label and never crosses a dot, and every regex is
anchored at both ends, so `*.example.com` cannot be satisfied by
`example.com.evil.net`.

The expander is deliberately loud: an entry it cannot use is dropped with a
message on stderr (`docker logs claudebox-proxy`), never in silence. It refuses
`*` and `.` outright — they would allow every host — warns when an entry covers
a whole TLD, and falls back to a never-matching placeholder if the list ends up
empty, so an empty allowlist denies everything rather than depending on how
Squid treats an ACL file with no values.

It also **folds overlapping entries**, which is not cosmetic: see the traps
below.

`claudebox allow <domain>` appends and reloads; `claudebox reload` re-applies
the file after a manual edit. Both validate with `squid -k parse` before
applying and roll back to the previous list if the result would not load, so a
bad entry cannot take egress down.

Both also **compare the host file against the proxy's view of it first** and
remount when they disagree — see the stale bind mount trap below. Every launch
checks this too, so a session cannot start against a list the proxy is not
actually using.

Required entries come from <https://code.claude.com/docs/en/network-config> —
**treat that page as the source of truth and re-check it when Claude Code
updates**, since a new required host shows up as a confusing runtime failure
rather than a clear error.

Currently allowed: `api.anthropic.com`, `claude.ai`, `claude.com`,
`platform.claude.com`, `downloads.claude.ai`, `code.claude.com`,
`storage.googleapis.com`, `raw.githubusercontent.com`, `registry.npmjs.org`,
`.ddev.site`, `.docker.io`, `production.cloudflare.docker.com`,
`production.cloudfront.docker.com`, `*.github.com`, `*.githubusercontent.com`,
`*.github.io`, `*.debian.org`, `*.alpinelinux.org`, `*.wordpress.org`,
`*.woocommerce.com`, `*.packagist.org`, `getcomposer.org`.

The `*.` entries were already written in the file before wildcards were
supported, where they matched nothing. They take effect now — that widening is
the point of the change, but it is a widening.

Commented out but pre-written: MCP connectors, Chrome bridge, Datadog telemetry,
GitHub, apt, pip, composer.

Because the Datadog telemetry hosts are blocked, the compose file sets
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` so Claude Code suppresses those
requests instead of retrying them against a wall.

**When something in the box fails to connect, run `claudebox denied` first** —
it prints the exact `CONNECT host:port` lines Squid refused, which is almost
always the answer.

## Node in the box

Two settings in `docker-compose.yaml` make ordinary Node code work without every
program needing to know it is behind a proxy.

**`NODE_USE_ENV_PROXY=1`** — Node ignores `HTTP_PROXY`/`HTTPS_PROXY` by default,
for `fetch()` and for the `http`/`https` core clients alike. Node 22.23 honours
them when this is set, `NO_PROXY` included. Verified: without it both `fetch()`
and `https.get()` fail; with it both work, `dind` is still reached directly
rather than through Squid, and a denied host is still denied. This replaces the
`https-proxy-agent`/`http-proxy-agent` shim that used to be needed, along with
its dependency on some project's `node_modules`. It is also better behaved —
overriding `globalAgent` sent `NO_PROXY` hosts through the proxy too, which
breaks Node talking to `dind`.

**`NODE_OPTIONS=--require .../proxy-bootstrap.cjs`** — preloads
`node-proxy-bootstrap.cjs` into every Node process, for the part Node cannot
fix. A library that calls `dns.resolve()` to decide whether it is online gets a
failure, because the box has no resolver, and concludes it is offline even
though the proxy can reach the host. wp-env's `canAccessWPORG()` does exactly
this. The shim stubs resolution for the domains in `CLAUDEBOX_DNS_STUB`
(default `wordpress.org`; a comma-separated suffix list, `*` for everything,
empty to disable) so the check passes. **Nothing is bypassed** — the connection
that follows still goes through the proxy and is still subject to the allowlist.

The shim is baked into the image, not bind-mounted, for two reasons: a
bind-mounted single file can go stale (see the trap above), and a preload that
fails to resolve breaks *every* Node process in the box, Claude Code included.
For the same reason it never throws — any failure is an `emitWarning` and
execution continues. If `NODE_USE_ENV_PROXY` ever stops being set, it says so
rather than letting requests fail as phantom DNS errors.

`--disable-warning=UNDICI-EHPA` is in `NODE_OPTIONS` to silence undici's
"EnvHttpProxyAgent is experimental" notice, which otherwise prints on stderr in
every Node process. `NODE_NO_WARNINGS` would have hidden the shim's own
diagnostics too.

## What can and cannot use the proxy

Squid here is a `CONNECT` proxy and nothing else, so an HTTPS client has to do
two things: read the proxy variables, and open a tunnel. Most do. The ones that
do not fail in ways that look like a blocked domain, so they are worth knowing.

| Client | HTTPS through the proxy | Notes |
|---|---|---|
| `curl`, GNU `wget`, `git`, `apt`, `apk`, `composer`, `npm` | yes | read the env vars, issue `CONNECT` |
| PHP's `curl` extension | yes | libcurl reads the env vars itself; this is what WordPress's HTTP API uses |
| Node | yes in the box | needs `NODE_USE_ENV_PROXY=1`, set in `docker-compose.yaml` |
| PHP stream wrappers (`file_get_contents('https://…')`) | **no** | ignore the env entirely; see below |
| busybox `wget` (most alpine images) | **no** | cannot `CONNECT` at all; `apk add wget` fixes it |

PHP's stream wrappers can tunnel perfectly well — they just never look at
`https_proxy`. Passing a context works, and Squid logs a normal
`TCP_TUNNEL/200 CONNECT`:

```php
// CLAUDEBOX_PROXY is "http://<ip>:3128"; a stream context wants a tcp:// URI.
$ctx = stream_context_create(['http' => [
    'proxy' => str_replace('http://', 'tcp://', getenv('CLAUDEBOX_PROXY')),
]]);
file_get_contents('https://example.com/', false, $ctx);
```

This is deliberately *not* fixed globally with an `auto_prepend_file` calling
`stream_context_set_default()`. That would work, but a stream context has no
`NO_PROXY` equivalent, so it would also send `http://dind:8888`,
`http://localhost` and sibling-container requests to Squid, which denies them —
trading a rare failure for a common one. Matomo's own `Piwik\Http` prefers curl,
so this seldom comes up in practice.

Nested containers get the standard proxy variables injected and nothing else
(that is all `proxies.default` carries), so a Node process in one will ignore
them unless its image or command sets `NODE_USE_ENV_PROXY` too.

## Known issues and caveats

### Design consequences (working as intended, but surprising)

- **Anything that ignores proxy env vars fails.** That is the enforcement
  mechanism. Claude Code itself handles proxies correctly (verified end to end).
  Node used to be the notable casualty — both `fetch()` and the `http`/`https`
  core clients ignored `HTTPS_PROXY`, so a bare `node -e 'fetch(...)'` failed
  with `EAI_AGAIN`, which reads as a DNS fault rather than a configuration one.
  That is handled now; see *Node in the box* below. A library that builds its
  own agent still bypasses all of it and fails, as it should.
- **Nested containers get the proxy automatically, and are still held to the
  allowlist.** `entrypoint.sh` writes `proxies.default` into the box's
  `~/.docker/config.json`, so the Docker CLI injects the proxy variables into
  everything it creates — `docker compose up` included, which is what made
  wp-env work without patching wp-env. They reach exactly what the box reaches:
  `example.com` is refused inside a nested container just as it is in the box.
  `CLAUDEBOX_PROXY` is still exported for anything that wants the address
  explicitly, and is still an address rather than a name because dind's embedded
  DNS has never heard of `proxy`.

  The trap this introduces: HTTP *between* two nested containers now goes to the
  proxy too, and is denied, since a Compose service name is not on the allowlist
  and cannot sensibly be put there. Database traffic is unaffected — it is not
  HTTP — which is why wp-env is fine. If some nested stack does talk HTTP to its
  own service names, add those names to `noProxy` in `entrypoint.sh` rather than
  switching the injection off.

- **The `db:3306` bridge serves one project at a time.** `BOX_DDEV_PROJECT`
  picks it; the launcher auto-detects only when exactly one project is running,
  and otherwise prints that `db` is unmapped. Starting a second project does not
  change an already-running bridge — the launcher re-evaluates on the next
  launch, and Compose recreates the container when the target changes.
- **No `ddev` CLI or Docker socket in the box, and that stays true even with the
  relay.** Giving the box either would be root-equivalent on the host. Worse,
  DDEV's `hooks:` support `exec-host:`, which runs **on the host** — and Claude
  has write access to `.ddev/config.yaml` in the mounted tree. Any path that lets
  the box run `ddev start`/`ddev <anything>` on a project it can edit is host RCE
  by construction. `~/Projects/matomo/.ddev/config.yaml` already uses `exec-host:`.
  This is exactly why the ddev-exec relay **never runs the `ddev` binary** and
  never runs `ddev start`: it issues a raw `docker exec` into an
  already-running `ddev-<project>-<service>` container, so no DDEV hook — and no
  `exec-host:` — ever fires, and no project is started or reconfigured. The relay,
  not the box, holds the socket, and its code only ever performs that one exec.
  See *`ddev exec` works in the box via a scoped relay* above.
- **The workspace is mounted read-write into `dind`**, so a nested container can
  write to the source tree. Same access the box already has — no new *host*
  exposure — but change that mount to `:ro` if you want nested containers unable
  to write.
- **The dind API is plain TCP on 2375 with TLS disabled**, reachable only from
  `claudebox_inner`. Unauthenticated to anything else attached to that network.
- **The host and the box can show identically-named containers that are not the
  same container.** wp-env derives its names from a hash of the project path, so
  running it on the host and in the box against the same checkout produces
  `wp-env-wp-matomo-<samehash>-cli-1` in both daemons. Compare container IDs, not
  names, when working out which one you are looking at.
- **PHP in the box is 8.2** (Debian bookworm) while the matomo DDEV project pins
  7.2. Fine for reading code; misleading if Claude runs `php -l` and judges 7.2
  compatibility from it. Use a nested container for version-accurate checks.
- **`~/.claude` is seeded once, then diverges.** The host copy is mounted
  read-only at `/host/claude` and copied in on first start, minus `projects/`,
  `shell-snapshots/`, `todos/`, `file-history/`, `statsig/`, `logs/`. Later host
  changes do not propagate. To re-seed: `docker volume rm claudebox-home`.
- **`docker volume rm claudebox-home` also drops the box's login.** Credentials
  live in that volume.
- **Squid's access log is per-container-lifetime.** Restarting or rebuilding the
  proxy resets what `claudebox denied` can show.

### Traps that cost time during the build

Do not re-introduce these.

- **A missing `NODE_OPTIONS` preload breaks every Node process in the box**,
  Claude Code included, with `Cannot find module`. The path in
  `docker-compose.yaml` and the `COPY` in `Dockerfile` have to move together,
  and the image must be rebuilt when they do — compose alone will happily point
  a fresh container at a file the old image does not contain.

- **`claudebox rebuild` is required after editing `Dockerfile`, `entrypoint.sh`,
  `node-proxy-bootstrap.cjs`, or `proxy/squid.conf`.** `compose up -d` reuses the existing image and the
  edit silently has no effect. `allowlist.conf` is the exception — it is
  bind-mounted, so `claudebox allow` reloads it live.

- **A network created inside dind can shadow `claudebox_inner` and cut the
  daemon off from the proxy.** Every registry pull failed with
  `proxyconnect tcp: dial tcp 172.21.0.2:3128: connect: connection refused`,
  while `curl` to that same address from the box worked and the allowlist was
  not involved. `claudebox_inner` had been assigned `172.21.0.0/16` by the host
  daemon; a nested `docker compose up` (wp-env) then asked *dind's* daemon for a
  network and it allocated `172.21.0.0/16` as well, from the identical default
  pool. dockerd runs inside RootlessKit's network namespace, where that range is
  now a directly attached bridge, so packets for the proxy went to the local
  bridge instead of out through slirp4netns. Nothing logs a conflict: the two
  daemons cannot see each other's allocations, which is the whole point of the
  sidecar.

  Diagnosing it: `docker run --rm --network host alpine ip route` **inside the
  box** prints dind's namespace, and the proxy's subnet appears there as a `br-*`
  device. The fix is the pinned subnet above — do not "fix" it by giving dind
  host networking or by putting the box and dind on the same bridge.

  The failure is also asymmetric in a way that misleads: `docker exec
  claudebox-dind nc -z <proxy> 3128` succeeds, because that lands in the
  *container's* namespace, one layer above the daemon's.
- **Two settings inside the DDEV web container make it a stand-in for a
  single-host CI runner**, and claudebox owns both — `ddev-realip.conf` and
  `ddev-fixups` here, applied by `claudebox-ddev-fixups` in the box. Nothing is
  added to the project.

  - *Client IP.* Matomo's UI-test tracker proxy records the visitor from
    `REMOTE_ADDR`, which on a runner is `127.0.0.1` and is baked into every
    visits-log baseline. `ddev-http` sends the real client in `X-Real-IP` and
    Apache is told to take `REMOTE_ADDR` from it. **`mod_remoteip` does not work
    here** — enabled and configured at both server and vhost scope, PHP still
    saw the peer address, because it never reaches the FastCGI environment. Do
    not retry it; override the variable php-fpm is handed
    (`ProxyFCGISetEnvIf`).
  - *Path alias.* The runner is in the box, where the project sits at its host
    path, while Matomo is served from `/var/www/html`, and
    `TestsSetupFixture::createSymbolicLinksForUITests()` writes
    `tests/PHPUnit/proxy/{matomo.js,plugins,libs,…}` as *absolute* symlinks. They
    all dangle in the web container: `matomo.js` 404s, the JS tracker never
    runs, and the visits log is empty with broken icons throughout. Symlinking
    the host path to `/var/www/html` there fixes it whichever way the links were
    written; relative symlinks are the alternative, but they need
    `--keep-symlinks` on every run to survive.

  Both are applied over `ddev exec` — writing a config file and reloading Apache
  is squarely inside what the relay already permits, so this needed no new
  capability, no container in the project's namespace, and no long-running
  process. An earlier attempt did use a forwarder sharing the web container's
  network namespace; it works (that is how the loopback origin was proved) but
  it needs a tool the image may not ship, leaves a process behind, and opens a
  port on `ddev_default` that anything could use to arrive as `127.0.0.1`. The
  config file has none of those properties.

  **Both live in that container's filesystem, so `ddev restart` discards them.**
  The launcher re-applies on every run, so any session it starts is correct.
  Anything else is repaired by running `claudebox-ddev-fixups` in the box —
  deliberately the same code path, so the launcher exercises it every time.

  The failure mode is what makes this worth documenting rather than automating
  further: nothing errors. The suite runs and produces wrong pixels, which looks
  finished. `box-CLAUDE.md` therefore tells the box's Claude to run
  `claudebox-ddev-fixups --check` *before* regenerating any baseline, not just
  after noticing a diff. A poller was considered and rejected — it would add a
  container that can itself fail silently, to notice something the agent looking
  at the diff notices anyway.

- **Screenshot tests can fail on fonts while using exactly the right font.**
  Matomo's UI baselines are rendered on `ubuntu-24.04` runners. Debian and
  Ubuntu ship the same *upstream* font versions from different package
  revisions — `fonts-dejavu-core` 2.37-6 against 2.37-8 — and those files are
  not byte-identical. Same font, same metrics, same layout, every glyph a pixel
  off, which is what the comparison fails on.

  It reads exactly like a wrong-font problem, and chasing that wastes the day:
  the tempting fix is to install more fonts. What settled it was overlaying a
  failing screenshot on its baseline — **word positions and widths were
  identical and only the glyph interiors differed**. Different font selection
  reflows text; different rasterisation does not. If positions match, stop
  looking at which font and start looking at which *build* of it.

  The image therefore lifts DejaVu, Liberation and Noto Color Emoji out of an
  `ubuntu:24.04` build stage, and enables the two fontconfig rules Ubuntu has
  and Debian lacks (`10-sub-pixel-rgb`, `70-no-bitmaps-except-emoji` — Debian's
  `70-no-bitmaps` silently discards the emoji font). Separately, CI's own
  Arial/Verdana/Courier New come from `matomo-org/github-action-tests`. Verify
  with the md5 check under *Verifying a change*.

  Note what does **not** matter here: the box's FreeType version. Chromium
  bundles its own, and asks fontconfig only for the font file and the hinting
  preferences — which is why aligning those two things is enough.

- **Root-owned files inside `$HOME` surface as an `EACCES` nowhere near the
  cause.** The image sets `HOME=/home/<user>` for *every* user, so one
  `docker exec -u 0 …` that happens to run npm writes root-owned entries deep
  inside `~/.npm/_cacache`. Later npm runs as the box user then fail with
  `EACCES` on a path several directories from anything obviously root-related,
  while `~/.npm` itself still looks correctly owned — so a top-level check
  clears it. `entrypoint.sh` sweeps for this on every start and reports what it
  reclaimed. Do not widen that sweep to `~/Projects` or `~/.claude/plans`: both
  are host binds, and plans files can legitimately read as uid 0 in the box
  while being correctly owned on the host.

- **Busybox `wget` cannot issue `CONNECT`, and the failure reads as a blocked
  host.** `docker run --rm alpine wget https://…` fails for an *allowed* domain,
  with or without `--no-check-certificate` and even after adding
  `ca-certificates`. It is not TLS: the access log shows
  `GET https://woocommerce.com/` — busybox put the whole URL in a plain request
  line instead of opening a tunnel. Plain `http://` through the same busybox
  works, which makes the allowlist look guilty.

  `squid.conf` now denies non-CONNECT `https://` requests outright, so the client
  gets a printable `403` instead of `error getting response`, and the attempt
  appears in `claudebox denied` (unhandled it ended as `TCP_MISS_ABORTED`, which
  that command does not grep for — the one command meant to explain blocks stayed
  silent). `claudebox denied` calls the two cases apart in its output.

  Fix it at the client, not the proxy: use `curl`, or `apk add wget` for a GNU
  wget that can tunnel — verified working. Serving those requests properly would
  mean Squid terminating TLS itself, which this build cannot do (`--with-gnutls`,
  no OpenSSL client) and which would put the client→proxy leg in cleartext even
  if it could.

- **A bind-mounted single FILE can go stale in the container, and a reload will
  not fix it.** An in-place append to `allowlist.conf` on the host did not reach
  the proxy: the host file was 3954 bytes, the container's view of the same
  inode 3919 — exactly the two appended lines missing. Docker Desktop's
  file-sharing layer kept serving the old contents. This defeats the "it's
  bind-mounted, so a reload is enough" property, because a reload re-reads the
  file *from inside the container*, which is where the stale copy lives:
  `claudebox allow` printed `proxy reloaded` while the domain stayed blocked.
  Only `docker restart` remounts it. Worse, the restart's own start-up
  `allowlist build` can win the race against the refresh and expand the old
  contents anyway, so a rebuild has to follow the remount.

  The launcher now compares `md5sum` on both sides before reloading and on every
  launch, restarts the proxy when they differ, and re-expands afterwards. Keep
  that check. If a change to the allowlist ever seems to have no effect, compare
  the two checksums first — the entry is probably fine and the file is not
  there.

- **Restarting the proxy wipes the DDEV hostnames** it holds in `/etc/hosts`,
  which is now reachable through `claudebox allow` and `claudebox reload`, not
  just a full launch. The hostname write is a function (`write_ddev_hosts`) and
  is called after every restart for that reason; do not inline it back into the
  launch path only.

- **Squid's `dstdomain` has no wildcards, and says nothing about it.**
  `*.example.com` in an ACL file is read as a literal hostname: it matches
  nothing, logs no warning, and looks correct in `claudebox allowed`. Six
  entries in `allowlist.conf` sat dead this way. This is why `allowlist.sh`
  exists, and why it reports every entry it drops instead of ignoring them
  quietly. Do not "simplify" it back into a direct bind mount of the source
  file onto the ACL path.

- **Overlapping `dstdomain` entries are FATAL, not a warning.** Once
  `*.githubusercontent.com` started working, it collided with the required
  `raw.githubusercontent.com` and Squid refused to start at all:
  `ERROR: 'raw.githubusercontent.com' is a subdomain of '.githubusercontent.com'
  ... FATAL: Bungled squid.conf`. The proxy is the only route out, so a dead
  proxy is a dead box. `allowlist.sh` folds covered entries; keep that, and keep
  the `squid -k parse` check that runs before any reload is applied.

- **The reload must not fall back to restarting the proxy when validation
  fails.** The rollback keeps the old ACL files in place, but a restart
  re-expands the same bad source with nothing to roll back to. `allowlist
  reload` exits 3 for exactly that case and the launcher treats it separately
  from a generic failure.

- **Word splitting in the expander needs `set -f`.** Reading entries with an
  unquoted `for entry in $line` also glob-expands, so a bare `*` in the
  allowlist expanded to the filenames in Squid's working directory and added
  each one as an allowed domain. Caught in testing; the `*` case is now refused
  outright as well.

- **`claudebox denied` needs `grep -a`.** The access log picks up stray bytes
  from tunnelled traffic, after which grep decides the file is binary and prints
  `binary file matches` instead of the lines — so the command that exists to
  explain a block silently stops explaining anything.

- **`pid_filename none` silently breaks `squid -k reconfigure`.** Reload needs
  the pid file to find the process. Symptom: `claudebox allow` reports success
  while the domain stays blocked. The launcher now falls back to restarting the
  proxy if reconfigure fails.
- **Squid drops privileges to the `proxy` user and cannot write `/dev/stdout`.**
  It exits with `FATAL: Cannot open '/dev/stdout' for writing`. Logs go to
  `/var/log/squid/` instead, which is why `claudebox denied` reads via
  `docker exec` rather than `docker logs`.
- **Docker Hub blobs come from `production.cloudfront.docker.com`** (CloudFront),
  not `cloudflare`. Getting this wrong makes manifests resolve and layer pulls
  fail with `Forbidden`.
- **`compose up -d` returns when the container *starts*, not when
  `entrypoint.sh` finishes.** Exec'ing in immediately lands in a half-seeded
  `$HOME`. The entrypoint touches `/run/claudebox.ready` last and the launcher
  polls for it. Keep that ordering.
- **The launcher must resolve its own symlink.** It is invoked via
  `~/.local/bin/claudebox`, and `${BASH_SOURCE[0]}` is the path as invoked, so a
  bare `dirname` yields the symlink's directory and every path built from
  `BOX_DIR` (compose file, allowlist) breaks with
  `open /home/dizzy/.local/bin/docker-compose.yaml: no such file or directory`.
  Use `readlink -f` first. **Test through the symlink, not the direct path** —
  this shipped broken because every check during the build ran
  `~/.claudebox/claudebox` directly.
- **`sed -i` fails on `/etc/hosts` inside a container** (`Device or resource
  busy`) — it renames a temp file over a bind mount. Read the file, then
  truncate and rewrite in place.
- **`set -e` and `cmd && other` don't mix in the launcher.** A failing
  `[ -n "$x" ] && y=1` aborted the script mid-run. All such tests are now
  explicit `if` blocks; keep them that way.
- **`ddev-router` outlives the last project it served**, so a non-empty router
  IP does not imply there is anything to map. The hostname list must be checked
  separately.
- **`ddev list -j` output is parsed defensively** (name + tld, plus any URL
  fields, deduped) because the schema is not guaranteed stable.

## Verifying a change

Rebuild, then run these. All should hold.

Run these as `claudebox ...` (through the `~/.local/bin` symlink), never as
`~/.claudebox/claudebox ...` — the direct path hides symlink-resolution bugs.

```bash
claudebox rebuild

# Isolation from host Docker — no host container may be visible in the box.
# Don't test this by counting: dind has containers of its own as soon as
# anything has been run in the box, and a count only reads 0 by luck.
claudebox shell -c 'for c in claudebox claudebox-proxy ddev-router; do
    docker inspect "$c" >/dev/null 2>&1 && echo "BAD: $c visible"
done; echo ok'

# No route, no external DNS — both must fail. Read /proc/net/route rather than
# using "ip": iproute2 is not installed in the box, so "ip route show default"
# fails with "command not found" and the check passes for the wrong reason.
# A default route is the line whose Destination field is 00000000.
claudebox shell -c 'awk "NR>1 && \$2==\"00000000\"" /proc/net/route | grep -q . && echo BAD || echo ok'
claudebox shell -c 'getent hosts example.com >/dev/null && echo BAD || echo ok'

# Allowlist: first reachable, second refused
claudebox shell -c 'curl -s -o /dev/null -w "%{http_code}\n" https://api.anthropic.com/'
claudebox shell -c 'curl -s -o /dev/null -w "%{http_code}\n" https://example.com/'

# Wildcards reach Squid as something it can match: the generated list must be
# non-empty and must contain no literal "*"
docker exec claudebox-proxy cat /etc/squid/allowlist.domains
claudebox shell -c 'curl -s -o /dev/null -w "%{http_code}\n" https://dl-cdn.alpinelinux.org/alpine/'

# Unusable entries are dropped loudly, "*" is refused, and the rest still
# expand. Writes only to /tmp -- it does not touch the real allowlist.
docker exec claudebox-proxy bash -c '
  printf "https://scheme.example\n*\n*.example.com\napi-*.example.com\n" > /tmp/t.conf
  ALLOWLIST_SRC=/tmp/t.conf ALLOWLIST_DOMAINS=/tmp/t.dom ALLOWLIST_REGEX=/tmp/t.re allowlist build
  cat /tmp/t.dom /tmp/t.re'

# The dind DAEMON can reach the proxy, not just the dind container. A pull is
# the only honest test -- it is dockerd itself, inside RootlessKit's netns, that
# has to get out. Also check that nothing in dind's namespace has claimed the
# proxy's subnet.
claudebox shell -c 'docker pull hello-world >/dev/null && echo ok'
claudebox shell -c 'docker run --rm --network host alpine:3.20 ip route'

# A Puppeteer-downloaded Chromium starts. The image ships the shared libraries,
# not the browser, so this also exercises the storage.googleapis.com allowance.
# Cleans up after itself; it costs ~120MB of the home volume while it runs.
claudebox shell -lc 'mkdir -p ~/.chromium-smoke && cd ~/.chromium-smoke &&
  npm i puppeteer@8 >/dev/null 2>&1 &&
  node -e "require(\"puppeteer\").launch({args:[\"--no-sandbox\"]})
      .then(async b => { console.log(await b.version()); await b.close(); })
      .catch(e => { console.error(e.message.split(\"\\n\")[1]); process.exit(1); })";
  rm -rf ~/.chromium-smoke'

# Nested containers reach the allowlist with no flags, and only the allowlist.
# The second one is the important half: injection must not have become a bypass.
claudebox shell -c 'docker run --rm alpine:3.20 wget -q -T 10 -O /dev/null http://matomo.ddev.site/ && echo ok'
claudebox shell -c 'docker run --rm alpine:3.20 wget -q -T 10 -O /dev/null http://example.com/ && echo BAD || echo ok'

# HTTPS from a nested container needs a client that can tunnel -- busybox wget
# cannot, and fails identically to a blocked host. Use curl.
claudebox shell -c 'docker run --rm php:8.3-cli curl -s -o /dev/null -w "%{http_code}\n" --max-time 20 https://woocommerce.com/'

# Screenshot assertions need both of these; "compare" alone is not enough.
claudebox shell -c 'compare --version | head -1; identify --version | head -1'

# Font parity with the ubuntu-24.04 runners Matomo renders its baselines on.
# Both md5s must match, and rgba must be 1 -- not "a font by that name exists".
claudebox shell -c '
  md5sum /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
         /usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf
  fc-match -v sans-serif | grep -E "rgba|hintstyle"
  docker run --rm ubuntu:24.04 sh -c "
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq fonts-dejavu-core fonts-liberation >/dev/null 2>&1
    md5sum /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
           /usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"'

# The two CI-shaped names. The second must serve the DDEV project, and the
# third must still fail -- reaching host.docker.internal is not a way out.
claudebox shell -c 'docker run --rm -d -p 8888:80 alpine:3.20 sleep 30 >/dev/null;
  sleep 2; nc -z 127.0.0.1 8888 && echo "localhost:8888 ok"'
# The box itself must resolve and reach the same name -- Chromium runs here.
# curl agreeing is not sufficient evidence that Chromium will; check both.
claudebox shell -c 'getent hosts host.docker.internal &&
    curl -s -o /dev/null -w "box -> host.docker.internal: %{http_code}\n" \
    --max-time 25 http://host.docker.internal/matomo.js'

# The client IP the project sees through it must be 127.0.0.1, matching what a
# single-host runner records. Drop a probe in the docroot, read it, remove it:
claudebox shell -c 'p=~/Projects/<project>/hdr-probe.php
  printf "<?php foreach (\$_SERVER as \$k=>\$v) if (strpos(\$k,\"HTTP_X_\")===0) echo \"\$k=\$v\\n\";" > "$p"
  curl -s --max-time 20 http://host.docker.internal/hdr-probe.php; rm -f "$p"'

# NOTE: no --noproxy here, on purpose. Passing it makes this pass even when the
# injected NO_PROXY is missing host.docker.internal, which is the one thing this
# check exists to catch -- Squid answers 403 for that name.
claudebox shell -c 'docker run --rm --add-host host.docker.internal:host-gateway php:8.3-cli \
  curl -s -o /dev/null -w "host.docker.internal -> %{http_code}\n" --max-time 25 \
  http://host.docker.internal/'
claudebox shell -c 'docker run --rm --add-host host.docker.internal:host-gateway php:8.3-cli \
  curl -s --max-time 12 -o /dev/null https://example.com/ && echo BAD || echo ok'

# Arial/Verdana/Courier New, which CI copies in from its own repo
claudebox shell -c 'fc-list : family | tr "," "\n" | sort -u | grep -E "^(Arial|Verdana|Courier New)$"'

# The DDEV database is reachable under the name Matomo's config already uses.
# Needs a running project; "claudebox" prints which one it bridged at startup.
claudebox shell -c 'php -r "\$c=@mysqli_connect(\"db\",\"db\",\"db\",\"db\",3306);
    echo \$c ? \"ok\" : \"FAILED: \".mysqli_connect_error(); echo PHP_EOL;"'

# Bypass attempt must fail even for an allowed host
claudebox shell -c 'curl -s --noproxy "*" --max-time 8 https://api.anthropic.com/ && echo BAD || echo ok'

# Node reaches the network with no per-program configuration, and the DNS
# preflight shim answers without opening a hole
claudebox shell -lc 'node -e "fetch(\"https://api.anthropic.com/\").then(r=>console.log(r.status))"'
claudebox shell -lc 'node -e "require(\"dns\").promises.resolve(\"wordpress.org\").then(console.log)"'
claudebox shell -lc 'node -e "fetch(\"https://example.com/\").then(()=>console.log(\"BAD\"),()=>console.log(\"ok\"))"'

# End to end -- also the real check that the NODE_OPTIONS preload has not
# broken Claude Code itself, since it is a node program too
claudebox -p 'Reply with exactly: gate-ok'
```

With a DDEV project running, also check TLS still validates through the proxy
(`ssl_verify_result` must be 0) and that file ownership is preserved:

```bash
claudebox shell -c 'curl -sS -o /dev/null -w "%{ssl_verify_result} %{http_code}\n" https://<project>.ddev.site/'
claudebox shell -c 'touch ~/Projects/.t' && stat -c '%U:%G' ~/Projects/.t && rm ~/Projects/.t
```

For DDEV-related changes, create a throwaway project rather than testing against
`~/Projects/matomo` (which is an upstream checkout with init hooks):

```bash
mkdir -p ~/Projects/smoketest && cd ~/Projects/smoketest
printf '<?php echo "ok\\n";\n' > index.php
ddev config --project-name=smoketest --project-type=php --docroot=. --php-version=8.3 --omit-containers=db
ddev start -y
# ... test ...
ddev delete -Oy && cd ~ && rm -rf ~/Projects/smoketest
```

## If asked to extend this

- **Add a domain** → `claudebox allow <domain>`, or edit `allowlist.conf` and
  reload. Never disable the allowlist wholesale to "make something work"; find
  the host with `claudebox denied`.
- **Add a tool to the box** → `Dockerfile`, then `claudebox rebuild`.
- **A browser fails to start with `error while loading shared libraries`** → the
  published dependency lists for headless Chromium are all incomplete in some
  direction; derive the real one instead of guessing. Run
  `ldd <chrome-binary> | grep "not found"` in the box, add the owning packages to
  the Chromium block in the `Dockerfile`, rebuild, repeat until it is empty. That
  is how `libxshmfence1` got there — it is absent from every list upstream
  publishes. `ldd` cannot see libraries opened with `dlopen` at runtime, so
  finish by actually launching the browser.
- **Change what the box's Claude knows about its environment** → `box-CLAUDE.md`,
  then `claudebox rebuild`. It lands at `/etc/claude-code/CLAUDE.md`, Claude
  Code's managed-policy memory path: loaded in every session in every directory
  and not excludable by settings. Don't move it to `~/.claude/CLAUDE.md` — HOME
  is a volume `entrypoint.sh` seeds once, so edits there would never land — or to
  `~/Projects/CLAUDE.md`, which the host's own sessions would then load. Keep it
  short; it costs context in every session.
- **Change proxy policy** → `proxy/squid.conf`, then `claudebox rebuild`.
- **Give the box the Docker socket or the `ddev` CLI** → read *No `ddev` CLI or
  Docker socket in the box* above first and surface the `exec-host:` host-RCE
  consequence to the user before doing it. It is their call, but it should be an
  informed one. Note that `ddev exec` is already handled by the scoped relay
  (`ddev-relay/`) without either — extend that before widening box access.
- **Reach another host/port on `ddev_default` from the box** → add a second
  fixed forward to `ddev-db`, or a sibling service modelled on it. Do not
  generalise it into a destination-taking TCP proxy: `ddev_default` has real
  egress, so a general forwarder is an allowlist bypass with extra steps.
- **Extend what the box can do with DDEV** → the relay (`ddev-relay/relay.mjs`)
  is the trust boundary; keep it small and allowlist-driven. It runs `docker
  exec` only, never the `ddev` binary (which would fire `exec-host:` hooks on the
  host). Don't add operations that start/stop/reconfigure projects.
