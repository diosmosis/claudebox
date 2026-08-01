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
                    ┌─────────────────────────────────────────────┐
                    │  claudebox    claudebox-dind    ddev-relay   │
                    │      │              │               │        │
                    │      └──── proxy ───┘               │        │
                    └────────────│────────────────────────┼───────┘
                                 │        host docker.sock ┘ → docker exec
                                 │                             ddev-<project>-<svc>
                                 ├── claudebox_edge ──→ internet (allowlist)
                                 └── ddev_default ────→ ddev-router
```

| Container | Image | Role |
|---|---|---|
| `claudebox` | built from `Dockerfile` | Where Claude Code runs. No route off `claudebox_inner`. |
| `claudebox-proxy` | built from `proxy/Dockerfile` | Squid forward proxy. The only container with egress. Also the only one that can reach `ddev-router`. |
| `claudebox-dind` | `docker:dind-rootless` | Private rootless Docker daemon on `tcp://dind:2375`. |
| `claudebox-ddev-relay` | built from `ddev-relay/Dockerfile` | Holds the host Docker socket; runs `ddev exec` in DDEV containers on the box's behalf. On `inner` only — no egress. See below. |

| Network | Kind | Members |
|---|---|---|
| `claudebox_inner` | `internal: true` | claudebox, dind, proxy, ddev-relay |
| `claudebox_edge` | bridge | proxy only |
| `ddev_default` | external (DDEV's) | proxy only |

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
  validate inside the box.

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

## Technologies

| Component | Version at build | Notes |
|---|---|---|
| Base image | `node:22-bookworm-slim` | node 22.23.1 |
| Claude Code | 2.1.218 | installed via `npm i -g @anthropic-ai/claude-code` |
| Proxy | Squid 5.7 on `debian:bookworm-slim` | |
| Nested daemon | `docker:dind-rootless` | server 29.6.2 |
| Host Docker | Docker Desktop on Linux, 29.6.2 | socket at `~/.docker/desktop/docker.sock` |
| DDEV | v1.25.3 | `performance_mode: none`, so plain bind mounts |
| Also in the box | git, ripgrep, jq, curl, php-cli 8.2, composer, docker CLI + compose plugin | |

## Files

| Path | Purpose |
|---|---|
| `docker-compose.yaml` | The three services, three networks, two volumes |
| `Dockerfile` | The claudebox image |
| `entrypoint.sh` | Runs as root at start: installs the mkcert CA, seeds `~/.claude`, signals readiness |
| `ddev-shim` | The box's `ddev` (baked to `/usr/local/bin/ddev`); forwards `ddev exec` to the relay |
| `ddev-relay/Dockerfile`, `ddev-relay/relay.mjs` | The scoped `ddev exec` relay image and server |
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

Env overrides: `BOX_WORKSPACE`, `BOX_USER`, `BOX_HOST_HOME`, `BOX_MKCERT_CA`.

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
`*.packagist.org`, `getcomposer.org`.

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

## Known issues and caveats

### Design consequences (working as intended, but surprising)

- **Anything that ignores proxy env vars fails.** That is the enforcement
  mechanism. Claude Code itself handles proxies correctly (verified end to end).
  Node used to be the notable casualty — both `fetch()` and the `http`/`https`
  core clients ignored `HTTPS_PROXY`, so a bare `node -e 'fetch(...)'` failed
  with `EAI_AGAIN`, which reads as a DNS fault rather than a configuration one.
  That is handled now; see *Node in the box* below. A library that builds its
  own agent still bypasses all of it and fails, as it should.
- **Nested containers have no egress by default.** Deliberate — otherwise
  `docker run alpine wget evil.com` is a trivial bypass. When one genuinely
  needs network: `docker run -e https_proxy=$CLAUDEBOX_PROXY ...`, which lands
  on the same allowlist. Nested containers cannot resolve the name `proxy`
  (dind's embedded DNS doesn't know it), which is why the launcher injects the
  IP-based `CLAUDEBOX_PROXY`.
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

# No route, no external DNS — both must fail
claudebox shell -c 'ip route show default | grep -q . && echo BAD || echo ok'
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
- **Extend what the box can do with DDEV** → the relay (`ddev-relay/relay.mjs`)
  is the trust boundary; keep it small and allowlist-driven. It runs `docker
  exec` only, never the `ddev` binary (which would fire `exec-host:` hooks on the
  host). Don't add operations that start/stop/reconfigure projects.
