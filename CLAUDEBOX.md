# claudebox

Context for Claude. Read this before modifying anything in `~/.claudebox/`.

## Purpose

Run a coding agent — Claude Code or opencode — against every project under
`~/Projects` from a single isolated container, instead of installing it
per-project or on the host.

Three requirements drove the design, in order:

1. **One box, not one per project.** `~/Projects` is the root for all work.
2. **Isolation.** The agent runs in its own container; the host filesystem is not
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
                    │                                                                │
                    │            runner-relay ── claudebox_edge ──→ LAN ──→ another   │
                    │             (token +                                  machine's │
                    │              pinned cert)                             runner    │
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

  claudebox-sync ── claudebox_edge ──→ LAN ──→ another machine's syncer
   (sshd, keys only, mutagen's transport.                 │
    NOT on inner: it holds the same             claudebox-mutagen ── edge
    workspace bind the box does, and             (mutagen daemon; keeps a real
    nothing else)                                 local COPY, which is what
                                                  BOX_WORKSPACE_HOST points at)
```

| Container | Image | Role |
|---|---|---|
| `claudebox` | built from `Dockerfile` | Where the agent runs — Claude Code or opencode, same container either way. No route off `claudebox_inner`. |
| `claudebox-proxy` | built from `proxy/Dockerfile` | Squid forward proxy. The only container with egress. Also the only one that can reach `ddev-router`. |
| `claudebox-dind` | `docker:dind-rootless` | Private rootless Docker daemon on `tcp://dind:2375`. |
| `claudebox-ddev-relay` | built from `ddev-relay/Dockerfile` | Holds the host Docker socket; runs `ddev exec` in DDEV containers on the box's behalf. On `inner` only — no egress. See below. |
| `claudebox-ddev-db` | `alpine/socat` | One fixed TCP forward: `db:3306` on `inner` → `ddev-<project>-db:3306` on `ddev_default`. Lets PHP in the box use a DDEV project's database. See below. |
| `claudebox-ddev-http` | built from `ddev-http/Dockerfile` | nginx on a fixed address: sets `Host` to the project's hostname, presents the client as `127.0.0.1`, and proxies to the project's web container. This is what `host.docker.internal` resolves to, in dind and in the box. See below. |
| `claudebox-sync` | built from `sync-server/Dockerfile` | An sshd over the **same workspace bind the box gets**, published on the LAN, so another machine can keep a live local copy of this source tree and run its own claudebox against the copy. Only mutagen's transport — mutagen itself is never installed here; the other machine copies an agent in. On `edge` only. Created under the `sync` profile. |
| `claudebox-mutagen` | built from `mutagen-client/Dockerfile` | The syncer, on the machine that *borrows* a workspace: a mutagen daemon and an ssh client keeping `~/.claudebox/synced-workspace` in step with a remote door. A container because mutagen takes no per-session ssh options and would otherwise need to write the user's own `~/.ssh/config`. On `edge` only, and never `inner` — it holds a key another machine's door trusts. Created under the `mutagen` profile. |
| `claudebox-runner-relay` | built from `runner-relay/Dockerfile` | Holds a remote test runner's address, token and certificate fingerprint; forwards five routes to it and nothing else. On `inner` *and* `edge`, which is the only reason the box can reach another machine at all. Idle and harmless when no runner is joined. See below. |

| Network | Kind | Members |
|---|---|---|
| `claudebox_inner` | `internal: true` | claudebox, dind, proxy, ddev-relay, ddev-db, ddev-http (`10.99.1.10`), runner-relay |
| `claudebox_edge` | bridge | proxy, runner-relay, agent-relay, sync, mutagen |
| `ddev_default` | external (DDEV's) | proxy, ddev-db, ddev-http |

| Volume | Contents |
|---|---|
| `claudebox-home` | Container `$HOME` (`/home/dizzy`), including its own `~/.claude` — except `~/.claude/plans`, which is a host bind (see below) |
| `claudebox-dind-data` | dind's image store — separate from the host's |
| `claudebox_sync-state` | The workspace door's host key, authorized_keys, and the login user's home (where mutagen installs its agent). Only under the `sync` profile; deleting it issues a new host key, which every machine that attached has pinned |
| `claudebox_mutagen-state` | The syncer's daemon state, session database and agent cache. Only under the `mutagen` profile |

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

- **The host side of that bind is configurable, the box side is what everything
  else is built on.** `BOX_WORKSPACE` is the path the box sees; `BOX_WORKSPACE_HOST`
  is the host directory bound there and defaults to `BOX_WORKSPACE`, which is
  what keeps the 1:1 mapping above true unless it is set. Setting it alone —
  `BOX_WORKSPACE_HOST=/mnt/ssd/projects` — puts the tree on another drive while
  the box, `dind` and the relay all still see a plain `~/Projects`; the launcher
  translates between the two for the working directory it exec's into and for
  the DDEV approot it hands the fixups. Pointing `BOX_WORKSPACE` at the drive
  instead, so both sides match again, also works and keeps paths clickable, but
  the box then carries the drive's path everywhere and a mount point under
  `/media` collides with the staged-material mount. Two costs before moving a
  workspace onto a *removable* drive: the path has to go on Docker Desktop's
  file-sharing list (below), and sharing it pins the drive for as long as
  Desktop runs (below that) — `claudebox media add` remains the right tool for
  material only to be read.

- **`claudebox eject` is that order, and it refuses to claim more than it
  proved.** Stop DDEV projects whose approot is on the drive → `compose down` →
  `udisksctl unmount` → `udisksctl lock`, and only the lock succeeding earns
  "safe to unplug". Two traps found while building it, both now in the code:
  `lsblk -no PKNAME` reports an **empty** parent for a device-mapper node (use
  `-s`, the inverse tree), and the first version read that empty string as "not
  encrypted", skipped the lock, and declared a still-open LUKS volume safe to
  unplug. So a path that cannot prove a release now says so and exits non-zero —
  including a plain unencrypted filesystem, where `--power-off` is the only
  thing here that can prove it.

- **A removable workspace must be released in one order, and a successful
  `umount` does not mean it was.** Measured on the native engine with the
  workspace on a LUKS/ext4 drive: with the box running, `udisksctl unmount`
  **succeeds** and the host mountpoint disappears — but the container's mount
  namespace still holds the filesystem (it goes on reading the tree fine), and
  `udisksctl lock` then fails with `Device or resource busy`. The drive is not
  safe to pull at that point, and nothing about the unmount says so. Stop the box
  first and all three steps pass:

  ```
  claudebox stop
  udisksctl unmount -b /dev/mapper/luks-<uuid>
  udisksctl lock -b /dev/sdb1      # "Locked" = genuinely released
  ```

  This is still a large improvement on Docker Desktop, where the unmount itself
  returned `EBUSY` and only *quitting Desktop* released the drive — the pin
  outlived every container. Here it outlives only the containers themselves.

- **`claudebox` refuses to start over a workspace that is not really there.**
  A missing bind source is silently *created* by Docker, root-owned — on an
  unmounted drive's mount point that means writing to the internal disk
  underneath it — and a host path off the file-sharing list fails at container
  create with an error that names the path but not the setting. So the launcher
  checks first: the host workspace must exist and be a directory (fatal), is
  warned about when empty (an unmounted drive looks exactly like a fresh
  workspace), and is checked against `FilesharingDirectories` when Docker
  Desktop's settings store is readable (fatal, with the ejection caveat in the
  message). Both workspace paths must also be absolute: Compose reads a relative
  volume source as a *named volume*, which would come up as an empty tree rather
  than an error.

- **The workspace is also mounted into `dind` at the path the box uses.** `-v`
  sources in a nested `docker run` are resolved by the *daemon*, not the client.
  Without this second mount, `-v /home/dizzy/Projects/x:/app` silently creates
  an empty directory instead of mounting the source. The box is the client, so
  the mount target here is the container-side path (`BOX_WORKSPACE`) even when
  the host directory behind it is somewhere else — same for the relay's
  read-only copy, which validates workdirs the box sent.

- **`$HOME` is a named volume with the bind mount nested inside it.** Docker
  orders mounts by path depth, so the volume lands on `/home/dizzy` first and
  the bind on `/home/dizzy/Projects` on top. Nothing else from the host home
  directory is exposed — no SSH keys, no cloud credentials.

- **`/media` in the box is staged material, not the host's drives.** The source
  is `~/.claudebox/media`, bind-mounted read-only, filled by `claudebox media
  add <path>` (`ls`/`rm` alongside it). Each entry is named after what was
  copied, re-running `add` refreshes it in place, and the command refuses a copy
  that would not fit. Because the source is an ordinary directory under `/home`,
  additions show up in a running box immediately — the old requirement to
  recreate the container for a drive plugged in mid-session is gone with it.

- **Binding the real `/media` was tried and reverted: it made removable drives
  impossible to eject without quitting Docker Desktop.** Not a container
  problem, and no bind flag fixes it. The engine here is a VM, and each entry in
  Docker Desktop's file-sharing list is exported to it by a `virtiofsd` process
  **on the host, started with the VM and killed only with the VM** — visible as
  `~/.docker/desktop/virtiofs.sock{0,1}.pid`, one per shared directory, whose
  logs bracket a whole Desktop session (`Client connected, servicing requests` …
  `Client disconnected, shutting down`). It keeps an open fd for every inode the
  guest looks up, so the moment the box walked into `/media/dizzy/<label>` those
  fds sat on the *drive's* filesystem and `umount` returned `EBUSY`. `claudebox
  stop` is a `compose down`: it removes containers, one layer above the share,
  and changes nothing. Only stopping the VM released the drive. `:ro`,
  `rprivate`, and sharing a single drive instead of `/media` all route through
  the same process, so staging a copy is the fix — it pays a copy to keep the
  drive ejectable at any moment. **Do not put `/media` back on the file-sharing
  list.**

- **Docker Desktop only passes through host paths on its file-sharing list.**
  The engine is a VM reached over `~/.docker/desktop/docker.sock` (context
  `desktop-linux`), not a plain host dockerd, and `FilesharingDirectories` in
  `~/.docker/desktop/settings-store.json` reads `["/home"]` — which is the whole
  reason `~/Projects` works. A bind of an unlisted path does not degrade to an
  empty directory the way an unmounted source does; the container refuses to
  start outright, with `mounts denied: The path /x is not shared from the host`.
  **Any future mount of a host path outside `/home` needs adding here first, or
  the box will not come up** — and needs weighing against the pin above, since
  the entry is live for the whole Desktop session. Editing the key takes a
  `docker desktop restart` (which stops every container on the host, DDEV
  included); the GUI's Settings → Resources → File sharing writes the same key.
  One consequence worth knowing: virtiofs presents shared files as the desktop
  user, so a shared path shows as `dizzy:dizzy` in the box no matter what it is
  on the host.

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
  `seccomp=unconfined`, `apparmor=claudebox-dind`, `systempaths=unconfined`, plus
  `/dev/fuse` and `/dev/net/tun`. `systempaths=unconfined` is the non-obvious
  one: Docker masks parts of `/proc` by default, and the kernel then refuses
  `mount -t proc` inside the nested user namespace. Without it, nested
  containers fail with `error mounting "proc" ... operation not permitted`.

- **The AppArmor profile is a prerequisite, and both launchers detect it rather
  than documenting it.** Ubuntu 24.04 sets
  `kernel.apparmor_restrict_unprivileged_userns=1`, which denies user-namespace
  creation to *unconfined* processes — so `apparmor=unconfined` is precisely the
  case that fails, and rootlesskit dies before dockerd starts with `fork/exec
  /proc/self/exe: operation not permitted`. `apparmor/claudebox-dind` is
  unconfined plus `userns`, granted to that one container:

  ```
  sudo cp ~/.claudebox/apparmor/claudebox-dind /etc/apparmor.d/
  sudo apparmor_parser -r /etc/apparmor.d/claudebox-dind
  ```

  `dind-apparmor.sh` is sourced by `claudebox` and `claudebox-runner` alike and
  runs two checks, because they fail at different times and neither covers the
  other. The **preflight** (before `compose up`) is cheap and predictive but can
  only see that the profile *file* exists — `/sys/kernel/security/apparmor/profiles`
  is root-only, so a launcher running as the user cannot confirm it was ever
  loaded. The **postmortem** greps the sidecar's log for that exact message when
  the stack fails to come up, which is authoritative and catches "file present
  but `apparmor_parser` never ran". Both print the same fix, with the calling
  checkout's path in it so the commands are copy-pasteable on either machine.
  `BOX_DIND_APPARMOR=unconfined` opts out entirely and silences both — right on a
  host with no AppArmor confinement, which is how this ran under Docker Desktop.

  This is code and not a README line because of where the symptom surfaces: the
  container exits 1, compose reports only that a dependency is unhealthy, and the
  cause is four layers down in a log nobody thinks to open. It cost a full
  debugging round here and would cost the same again on every new runner machine.

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
| opencode | 1.18.14 | installed via `npm i -g opencode-ai`; a Bun binary, so it ignores `NODE_OPTIONS` |
| Proxy | Squid 5.7 on `debian:bookworm-slim` | |
| Nested daemon | `docker:dind-rootless` | server 29.6.2 |
| Host Docker | Docker Desktop on Linux, 29.6.2 | socket at `~/.docker/desktop/docker.sock` |
| DDEV | v1.25.3 | `performance_mode: none`, so plain bind mounts |
| Also in the box | git, ripgrep, jq, curl, php-cli 8.2 (incl. `mysqli`/`pdo_mysql`, `gd`), composer, docker CLI + compose plugin, headless-Chromium shared libs, Xvfb (`xvfb-run`, for suites that drive a headful browser), imagemagick (`compare`/`identify`, for screenshot assertions) | ImageMagick's resource limits are raised to CI's values |
| Fonts | DejaVu / Liberation / Noto Color Emoji taken from `ubuntu:24.04`, plus CI's Arial, Verdana and Courier New | matched to the `ubuntu-24.04` runners so screenshot baselines compare; see the traps |

## Files

| Path | Purpose |
|---|---|
| `docker-compose.yaml` | The ten services (three of them behind profiles), three networks, five volumes |
| `Dockerfile` | The claudebox image |
| `entrypoint.sh` | Runs as root at start: installs the mkcert CA, seeds `~/.claude` and opencode's config/credentials, signals readiness |
| `ddev-shim` | The box's `ddev` (baked to `/usr/local/bin/ddev`); forwards `ddev exec` to the relay |
| `ddev-relay/Dockerfile`, `ddev-relay/relay.mjs` | The scoped `ddev exec` relay image and server |
| `ddev-http/Dockerfile`, `ddev-http/default.conf.template` | The `host.docker.internal` front door for nested containers |
| `ddev-fixups`, `ddev-realip.conf` | Baked in as `claudebox-ddev-fixups`; prepares a DDEV web container for UI tests (client IP, path alias) |
| `runner-shim` | The box's `runner` (baked to `/usr/local/bin/runner`); syncs a project to the remote runner and runs commands there |
| `runner-relay/Dockerfile`, `runner-relay/relay.mjs` | The relay that holds the runner's credential and forwards to it |
| `runner/Dockerfile`, `runner/runner.mjs`, `runner/entrypoint.sh` | The runner image (`FROM` the main Dockerfile's `base` stage), its API, and the first-start identity, DDEV and mkcert setup |
| `runner/open-enrolment.sh` | Baked in as `claudebox-runner-enrol`; opens an enrolment window (a fresh short code and expiry). Called by the entrypoint on a never-joined runner and by `claudebox-runner enrol` |
| `runner-relay/enrol.mjs` | Run as a one-off container by `claudebox runner add <host:port> <code>`: learns the runner's certificate, trades the code for the token, pins both |
| `ddev-bridge` | Baked into the runner image as `claudebox-ddev-bridge`; points `db:3306`, `host.docker.internal` and a project's hostnames at a DDEV project running inside the runner's dind |
| `docker-compose.runner.yaml` | The runner stack — runner + its own rootless dind + workspace volume — brought up on the *other* machine |
| `claudebox-runner` | Launcher for a runner machine, symlinked into `~/.local/bin` there |
| `agent-relay/relay.mjs`, `agent-relay/entrypoint.sh`, `agent-relay/open-enrolment.sh` | The inbound agent door on a workstation: its identity, its enrolment window, and the one route it forwards into the box |
| `agent-relay/enrol.mjs`, `agent-relay/send.mjs` | Run as one-off containers **on a runner machine** — join a workstation, and send it a headless run |
| `agent-serve.mjs` | Baked into the box as `/usr/local/lib/claudebox/agent-serve.mjs`; the box's side of that door, on the internal network only |
| `sync-server/Dockerfile`, `sync-server/entrypoint.sh`, `sync-server/sshd_config.template` | The workspace door: an sshd serving the same tree the box works in, as mutagen's transport. The entrypoint settles what the image does not bake in — which user may log in, which tree is served, and where that user's home is (**not** the workspace: that is where mutagen installs its agent) |
| `sync-server/authorize.sh`, `sync-server/info.sh` | Baked in as `claudebox-sync-authorize` and `claudebox-sync-info`. The first adds or lists authorised keys; the second is what the borrowing machine asks over ssh — it is both the authentication probe and how the served path is discovered |
| `mutagen-client/Dockerfile`, `mutagen-client/entrypoint.sh` | The syncer: a pinned mutagen release (binary **and** agent bundle, which must sit beside it) plus an ssh client. The entrypoint generates this machine's key and the `~/.ssh/config` mutagen reads — the whole reason it is a container |
| `dind-apparmor.sh` | Sourced by both launchers: the AppArmor preflight and postmortem for the rootless dind sidecar |
| `ui-parity` | Prints everything about an image that a UI test can observe, in diffable form — package versions, font file hashes, fontconfig's resolved settings, ImageMagick's limits |
| `apparmor/claudebox-dind` | The profile that grants `userns` to the dind sidecar; installed once with `sudo`, on each machine |
| `node-proxy-bootstrap.cjs` | Preloaded into every Node process via `NODE_OPTIONS`; DNS-preflight shim |
| `box-CLAUDE.md` | Baked to `/etc/claude-code/CLAUDE.md` **and** `/etc/claudebox/AGENTS.md`; what the box's agent is told about its own environment, one file for both |
| `box-opencode.json` | Baked to `/etc/claudebox/opencode.json`; the config `OPENCODE_CONFIG` points at, whose only job is adding `AGENTS.md` to opencode's instructions |
| `proxy/Dockerfile` | Squid image |
| `proxy/squid.conf` | Baked-in proxy policy |
| `proxy/allowlist.sh` | Expands `allowlist.conf` into Squid's ACL files; installed as `allowlist` |
| `allowlist.conf` | **Bind-mounted, user-editable.** The egress allowlist. Also mounted read-only into the box at `/etc/claudebox/allowlist.conf` so Claude can see what is permitted before guessing |
| `claudebox` | Host launcher, symlinked into `~/.local/bin` |
| `plugin-api.sh` | Sourced by the launcher **and** by plugin commands: path translation, the `docker exec` flags a session is attached with, and the helpers a plugin talks to the box with |
| `plugins/` | The launcher commands claudebox ships — `plugins/<name>/commands/<cmd>` is `claudebox <name>:<cmd>`. Tracked |
| `plugins/example/` | The worked plugin, and the thing to copy when adding one |
| `plugins/jira/` | `jira:config` and `jira:triage-issue` — fetch a JIRA issue on the host, then have a headless session in the box verify it and write a failing regression test |
| `plugin-state/` | Gitignored. Per-plugin scratch space, created on demand |
| `docker-compose.override.yaml` | Generated by the launcher; the `~/.claude/plans` bind plus any optional host mounts that exist |
| `plans/` | Host side of the `~/.claude/plans` bind — plans written in the box, readable here |

### Launcher commands

```
claudebox                  interactive session in the current directory
claudebox -p '...'         flags/prompt passed straight to claude
claudebox opencode [args]  opencode instead of claude, args passed straight to it
claudebox shell            bash in the box
claudebox rebuild          rebuild images (needed after Dockerfile/entrypoint edits)
claudebox stop             stop the stack (volumes survive)
claudebox allow <domain>   append to the allowlist and hot-reload the proxy
                           quote wildcards: claudebox allow '*.example.com'
claudebox reload           re-apply allowlist.conf after editing it by hand
claudebox allowed          show the allowlist
claudebox denied           show what the proxy has blocked

claudebox runner add <host:port> <code>
                           join a remote test runner using the 8-character
                           enrolment code its "claudebox-runner" prints. A
                           <token> <fingerprint> pair also works, from
                           "claudebox-runner join --full"
claudebox runner show      what is joined (the token is not printed)
claudebox runner test      ask it, through the relay, whether it answers
claudebox runner forget    un-join

claudebox agent start      serve the agent door here, for a machine that hosts a
                           runner: turns it on, brings it up, prints the join line
claudebox agent stop       stop serving it (the identity is kept, so no re-join)
claudebox agent enrol      open another enrolment window, for one more machine
claudebox agent status     whether that door is up, and its fingerprint
claudebox agent add <host:port> <code>
                           ON a runner machine: join that workstation, so headless
                           one-offs typed here are answered there
claudebox agent show|test|forget

claudebox mutagen start    share this machine's workspace, so another machine
                           can keep a live local copy of the same source tree
claudebox mutagen stop     stop sharing (host key and authorised keys are kept)
claudebox mutagen status   whether it is up, which machines may log in, and --
                           where attached -- whether the copy is really current
claudebox mutagen authorize '<public key>'
                           let a machine in. Keys only; there is no password
claudebox mutagen attach [user@]<host>[:port]
                           ON the other machine: keep a local copy in step with
                           that tree and point BOX_WORKSPACE_HOST at the copy,
                           so git runs at local-disk speed
claudebox mutagen detach   stop syncing (flushes first) and restore the local
                           workspace. The copy is kept
claudebox mutagen resolve --local|--remote
                           settle conflicts, which halt propagation both ways
claudebox mutagen forget [--purge]
                           drop the pin and the joined address
                           ("sync" is accepted everywhere "mutagen" is)

claudebox ps               what claude sessions are running in the box: how long,
                           which project, whether they came through the agent
                           door, and what each is executing right now
claudebox kill [<pid>]     stop one of them, and whatever it had started
                           (--all stops every one)
claudebox plugins          list the commands plugins add, and where they are looked for
claudebox <p>:<cmd> [args] run one (plugins/<p>/commands/<cmd>)

claudebox jira:config      set/show the JIRA site, account and API token (host only)
claudebox jira:triage-issue <KEY> [--project <path>] [--dir <path>] [--fetch-only]
                           fetch the issue here, then have the box verify it and
                           write a failing regression test on a new branch
```

Settings live in `~/.claudebox/config`, sourced as shell (see `config.example`,
which documents every one; `config` itself is gitignored as per-machine). The
**environment wins over the file**, so `BOX_WORKSPACE_HOST=/mnt/x claudebox`
stays a one-off — the launcher saves the environment's values, sources the file,
then puts them back, because a sourced assignment is unconditional and would
otherwise beat the command line. Only the enumerated names are honoured, so a
typo in the file is inert rather than mysterious.

Settings: `BOX_WORKSPACE` (where the box sees the tree), `BOX_WORKSPACE_HOST`
(the host directory bound there; defaults to `BOX_WORKSPACE`), `BOX_USER`,
`BOX_UID`, `BOX_GID`, `BOX_HOST_HOME`, `BOX_MKCERT_CA`, `BOX_DDEV_PROJECT`,
`BOX_DIND_APPARMOR`, `BOX_PLUGIN_PATH` (where plugins are looked for),
`BOX_AGENT_SERVE` / `BOX_AGENT_PORT` (serve an agent door here) and `BOX_AGENT` /
`BOX_AGENT_TOKEN` / `BOX_AGENT_FINGERPRINT` (written by `claudebox agent add` on
a runner machine), and
`BOX_RUNNER` / `BOX_RUNNER_TOKEN` / `BOX_RUNNER_FINGERPRINT` (written by
`claudebox runner add`, read by nothing but the relay), and
`BOX_SYNC_SERVE` / `BOX_SYNC_PORT` (share this machine's workspace) with
`BOX_SYNC_REMOTE` / `BOX_SYNC_FINGERPRINT` / `BOX_SYNC_REMOTE_PATH` /
`BOX_SYNC_LOCAL_WORKSPACE_HOST` / `BOX_SYNC_DIR` / `BOX_SYNC_MODE` /
`BOX_SYNC_IGNORE` / `BOX_SYNC_FLUSH_TIMEOUT` (written by `claudebox mutagen
attach` on the machine that borrows a workspace; `_LOCAL_WORKSPACE_HOST` is what
`detach` puts back).

`claudebox-runner` reads the same file with its own allowlist —
`BOX_USER`/`BOX_UID`/`BOX_GID`, `BOX_DIND_APPARMOR`, `BOX_RUNNER_PORT`,
`BOX_RUNNER_WORKSPACE`, `BOX_RUNNER_BASE_IMAGE` — since a machine is normally
one role or the other and the settings that matter differ.

### What the launcher does on each run

1. Checks the host workspace: exists, non-empty, on Docker Desktop's
   file-sharing list (also before `rebuild`, not before `stop` — a drive can be
   gone by then and `compose down` does not care).
2. Creates `ddev_default` if absent (DDEV reuses it as-is).
3. Regenerates `docker-compose.override.yaml`: always the `~/.claudebox/plans →
   ~/.claude/plans` bind (after `mkdir`ing the host side), plus the optional host
   mounts that actually exist — `~/.gitconfig`, `~/.config/opencode` and
   `~/.local/share/opencode/auth.json` — because binding a missing path would
   make Docker create a directory in the host home directory.
4. `compose up -d`, then **polls for `/run/claudebox.ready`** (see race below).
5. Checks the proxy's copy of `allowlist.conf` against the host's and remounts
   it (restart + re-expand) if they differ.
6. Resolves `ddev-router`'s IP and rewrites the proxy's `/etc/hosts`.
7. Injects `CLAUDEBOX_PROXY=http://<proxy-ip>:3128` into the exec environment.
8. Sets `TERM` for the exec — the host's own if the image has a terminfo entry
   for it, `xterm-256color` otherwise — and passes `COLORTERM` through. `docker
   exec -t` sets `TERM=xterm` and nothing else, which leaves a full-screen TUI
   drawing in eight colours; forwarding the host's blindly is not the fix
   either, since ghostty's `xterm-ghostty` and kitty's `xterm-kitty` are absent
   from Debian's ncurses and an unknown terminal type breaks `less` and `nano`
   in the box. `COLORTERM` is what the TUIs read for truecolor and needs no
   terminfo.
9. `docker exec`s in as uid/gid 1000, in the host cwd's counterpart inside the
   box — the same path when the workspace roots match, its translation when
   `BOX_WORKSPACE_HOST` differs, the root of the tree when the cwd is outside the
   workspace entirely — running `claude`, `opencode` or `bash` depending on the
   subcommand.

## Plugins

Launcher commands that live in a directory instead of in the dispatch:

```
plugins/my-plugin/commands/thing      ->  claudebox my-plugin:thing [args...]
```

`plugins/` is tracked, and holds the plugins claudebox ships — commands that
arrive with the tool, reviewed and versioned with it. There is no registration
step, no manifest and nothing generated: the directory being on the search path
*is* the installation. Adding a command is `cp -r plugins/example
plugins/<name>` and rewriting the scripts; nothing else in this repository
changes, which is the point. `claudebox plugins` lists what that produced.

`plugins/example` is the worked one, with the whole contract written out in its
README.

Only `plugins/` is searched by default. `BOX_PLUGIN_PATH` (colon-separated, a
setting like any other) replaces that list, for a plugin kept in its own
checkout or local to one machine; append the default rather than dropping it:

```sh
BOX_PLUGIN_PATH="${HOME}/my-plugins:${BOX_DIR}/plugins"
```

Duplicate entries are collapsed, and the first directory holding a given plugin
name wins.

### The shipped plugins

`example` is the worked one. `jira` is the first real one, and it is worth
reading before writing another, because it is shaped by the one thing a plugin
can do that a command in the box cannot: **it runs on the host.**

```sh
claudebox jira:config                  # site, account email, API token
claudebox jira:triage-issue AS-345     # fetch it, then triage it in the box
```

`triage-issue` fetches the issue with the API token *here*, writes it into the
project as `AS-345.md`, and then starts a headless session
(`claude -p ... --permission-mode auto`) — through the launcher, from the
project directory, so it gets the full launch path and the right working
directory — asking it to verify the report and write a failing regression test
on a new branch. The issue text goes **in the prompt**, not as a path to open,
so the run is self-contained; the file is still written, but nothing in the
prompt depends on it. An issue over ~100KB falls back to naming the file,
because `execve` caps one argument at 128KB and a prompt is one argument. Claude's answer is printed when it finishes and kept in
`plugin-state/jira/runs/`.

The token never crosses into a container, and that is a property of where it is
written rather than of anything the box is asked to respect:

- `plugin-state/jira/credentials`, `0600` in a `0700` directory, and **nothing
  mounts that path**. The box's binds are the workspace, `allowlist.conf`,
  `media/`, the mkcert CA, `plans/` and the host's `~/.claude` and
  `~/.claude.json` read-only — which is exactly why a credential must never be
  written under `~/.claude` or into the workspace.
- Compose `environment:` blocks are explicit lists of names. Nothing here is a
  launcher setting and no compose file names it, so no container's environment
  carries it.
- `allowlist.conf` has no Atlassian entry, so the box has no route to JIRA to
  spend a token on. **Do not add one to "make jira work"** — the fetch happens
  on the host and nothing in the box needs to reach JIRA.

It is kept out of the process table too: `curl` reads it from a config file on
stdin (`-K -`), never `-u`, and there is deliberately no `--token` flag, since
every process's arguments are world-readable and a token typed on a command line
is also in the shell history.

`lib/render-issue.js` turns Jira Cloud's ADF description into markdown — API v3
returns the description as a tree of typed nodes and has no markdown
representation to ask for. It is a dependency-free stdin-to-stdout filter, so it
runs under the host's node or, when the host has none, the box's node 22. That
fallback is not decoration: node installed through nvm is missing from a
non-interactive `PATH`, and `claudebox` assumes elsewhere that a host may have no
node at all.

### Why the colon

The launcher's default job is forwarding its arguments to `claude`, so a new
subcommand is normally a name taken away from the agent. `<plugin>:<command>` is
not: no built-in contains a colon, so a plugin can never shadow one, and the
`*:*` arm sits last in the dispatch where it could not anyway.

The reverse risk — swallowing a prompt that happens to start with a colon-word,
`claudebox 'TODO: fix the parser'` — is handled by only intercepting a reference
whose **plugin actually exists**:

| Argument | |
|---|---|
| `example:hello`, and `example` is a plugin | runs it, `exec`'d, so its exit status is the launcher's |
| `example:helo`, and `example` is a plugin | error listing `example`'s real commands, exit 2 — a typo is worth catching, not sending to an agent as a prompt |
| `nosuch:thing` | falls through to `claude` unchanged, like any other unrecognised argument |

Plugin and command names are `[A-Za-z0-9_][A-Za-z0-9_.-]*`. They become path
components, and without that restriction `claudebox ..:passwd` would be a way to
run an arbitrary executable.

### What a command is

Any executable, in any language, run **on the host** with everything the
launcher resolved exported: the `BOX_*` settings, plus `CLAUDEBOX_DIR`,
`CLAUDEBOX_CONTAINER`, `CLAUDEBOX_PROXY_CONTAINER`, `CLAUDEBOX_COMPOSE_FILES`,
`CLAUDEBOX_PLUGIN`, `CLAUDEBOX_PLUGIN_COMMAND`, `CLAUDEBOX_PLUGIN_DIR`,
`CLAUDEBOX_PLUGIN_STATE` (a scratch path under the gitignored
`plugin-state/<name>`, created only if the command asks for it — it is kept out
of `plugins/`, which is tracked, and out of the plugin's own directory, which
may be read-only) and `CLAUDEBOX_PLUGIN_API`.

A `# description: ...` line in the first 20 lines is what `claudebox plugins`
prints beside the command. A convention rather than a manifest — a plugin should
be a directory of scripts and nothing else.

Sourcing `${CLAUDEBOX_PLUGIN_API}` (`plugin-api.sh`) adds the vocabulary for
reaching into the box: `box_exec [-w dir] <cmd...>` and `box_exec_root`,
`box_running` / `box_require_running` / `box_start` / `box_wait_ready`,
`box_compose`, `box_path` / `host_path` / `box_workdir`, `plugin_state`, and
`plugin_say` / `plugin_die`.

`box_exec` is the launcher's own attach path minus the agent — same container,
same uid, same terminal handling, same working directory a session would start
in — because that file is where the launcher builds those flags too. That is the
reason it exists as a separate file rather than as a block of helper text in the
documentation: one implementation, sourced by both, so a plugin cannot get a
subtly different box from the one a session gets.

`box_start` deliberately shells back out to `./claudebox shell -c true` rather
than running `compose up` itself. Starting the box also means the workspace
checks, the dind AppArmor preflight, the allowlist resync and the DDEV hostname
rewrite; a plugin that reimplemented any of that would produce a box that is
almost right.

## Agents in the box

Two agents share one container. `claudebox` starts Claude Code, `claudebox
opencode` starts opencode, and everything around them is identical — same image,
same allowlist, same DDEV bridging, same working directory, same startup checks.
The subcommand only decides which program the final `docker exec` runs.

| | Claude Code | opencode |
|---|---|---|
| Installed by | `npm i -g @anthropic-ai/claude-code` | `npm i -g opencode-ai` — a launcher whose real payload is a ~180MB Bun binary, pulled as a per-platform optional dependency |
| Box notes | `/etc/claude-code/CLAUDE.md` (managed policy) | `/etc/claudebox/AGENTS.md`, via `OPENCODE_CONFIG=/etc/claudebox/opencode.json` |
| Config seeded from host | `~/.claude` (minus per-machine state), `~/.claude.json` | `~/.config/opencode` |
| Credentials seeded from host | inside `~/.claude` | `~/.local/share/opencode/auth.json` |
| Version moves on | `claudebox rebuild` | `claudebox rebuild` only — `OPENCODE_DISABLE_AUTOUPDATE=1` |

Both sets of box notes are the **same file**: `box-CLAUDE.md`, copied to two
paths at build time. Everything in it describes the container rather than the
reader, and two copies would drift.

opencode has no managed-policy path of its own, hence the baked config.
`OPENCODE_CONFIG` names an *additional* config rather than a replacement, so a
global `~/.config/opencode/opencode.json` seeded from the host still loads
alongside it. Check what actually resolved:

```bash
claudebox opencode debug config   # .instructions must contain /etc/claudebox/AGENTS.md
```

The two opencode host binds are built only when the paths exist, the same way
`~/.gitconfig` is, so a host without opencode installed seeds nothing. Both are
read-only and read exactly once: `entrypoint.sh` copies them into the HOME volume
on first start, and from then on the box's copies are its own — authenticating
inside the box never writes back to the host. Credentials are a separate mount
because opencode keeps them under `~/.local/share`, not with the config, and only
that half is a secret.

Two things follow from opencode being a Bun binary rather than a Node program:

- **It ignores `NODE_OPTIONS`**, so the DNS-preflight preload never loads into
  it. It does not need it — Bun's `fetch` reads `HTTP_PROXY`/`HTTPS_PROXY`/
  `NO_PROXY` on its own, and the cases the shim exists for are Node libraries'
  `dns.resolve()` online checks.
- **Self-update had to be disabled.** It would install into the HOME volume,
  which then shadows the image's copy, survives `claudebox rebuild` (volumes do)
  and drifts from what the Dockerfile says is installed.

Providers are reached directly, so only the model API's own host needs to be on
the allowlist — Anthropic's already is. `opencode.ai` and `models.opencode.ai`
carry the auth flow and the model catalogue; blocking them does not stop opencode
starting, it just falls back to a built-in catalogue, which is the kind of quiet
degradation `claudebox denied` exists to explain.

## Remote test runner

The agent runs here; the tests can run on a second machine on the LAN. A runner
is **the box minus the agent, plus a network API** — same image layers, so a
screenshot rendered there and one rendered here come out of the same fonts and
the same fontconfig rules.

```
  this machine                                    the runner machine
  ------------                                    ------------------
  claudebox ──POST {project, command}──▶ runner-relay ──TLS+token──▶ claudebox-runner
   (agent)      (claudebox_inner,               (holds address,          │  ddev, Chromium
                 internal: true)                 token, fingerprint)     │
                                                                         ├─ workspace volume
                                                                         └─ rootless dind
                                                                             ├─ ddev-router  :443
                                                                             ├─ ddev-<p>-web/-db
                                                                             ├─ front door   :80
                                                                             │   = host.docker.internal
                                                                             ├─ db forward   :3306
                                                                             └─ wp-env       :8888
```

Everything a project consists of lives inside the sidecar. The runner reaches it
only through ports published there, which is what shapes the three pieces below:
the database bridge, the `host.docker.internal` front door, and the loopback
forwarders.

### Why it is built this way

Two obvious approaches do not work, and it is worth knowing why before
simplifying this.

**Not `DOCKER_HOST=tcp://otherbox:2375`.** `-v` sources in `docker run` are
resolved by the *daemon*, not the client — a remote daemon looks for
`/home/dizzy/Projects/matomo` on its own disk, and when it is absent Docker
**silently creates an empty directory** rather than failing. Every DDEV and
wp-env mount depends on that resolving. And `claudebox_inner` is `internal: true`;
giving the box a route to a LAN host is what dismantles the sandbox, not the
`HTTPS_PROXY` variables. `tcp://host:2375` is also unauthenticated root on that
host.

**Not an ad-hoc DDEV + Chromium install on the target.** Baselines would drift.
Font *package versions* change glyph rendering — `fonts-dejavu-core 2.37-6`
against `2.37-8`, same upstream version, different bytes — and any environment
not built from the same layers produces UI-test diffs that look exactly like real
regressions. This is what the `base` stage in `Dockerfile` exists for.

### The base stage

`Dockerfile` has two stages that produce images:

| Stage | Contents |
|---|---|
| `base` | Fonts and the fontconfig rules that select them, Chromium's shared libraries, Xvfb, PHP + extensions, node, composer, the docker CLI, ImageMagick's raised limits, the box user |
| `claudebox` | `base` + the agents, the shims, the language servers, `box-CLAUDE.md` |

`runner/Dockerfile` is `FROM claudebox-base:latest`, and the rule for what may
be added there is **what a test can observe**. Fonts, PHP, node, Chromium's
libraries, ImageMagick's limits — anything that changes how code builds or how a
pixel comes out — belongs in `base`, where both images get the same layers.
Something missing for a test is a base problem, never a runner one.

An orchestrator is a different thing. DDEV starts containers from *pulled*
images, so the environment a DDEV-backed test runs in is `ddev/ddev-webserver`,
identical wherever it is pulled; the `ddev` binary itself is invisible to a test.
That is why it, `mkcert` and the single `sudo` rule live in `runner/Dockerfile` —
and it would be actively wrong to put `ddev` in `base`, since the box has no real
ddev at all and would end up with a second, conflicting one on its PATH. The
DDEV *version* is not invisible, though: a different ddev pulls different
webserver and dbserver images, so it is pinned to whatever runs on the machine
the baselines came from.

`claudebox-runner` builds `--target base` from this same file before building the
runner image, which is why the base image is a build ARG rather than a fixed tag.

`ui-parity` is how that claim is checked rather than assumed. It prints, in
diffable form, everything about an image a test can observe:

```bash
ui-parity claudebox:latest        > /tmp/box
ui-parity claudebox-runner:latest > /tmp/runner
diff /tmp/box /tmp/runner          # empty
```

Empty on this machine, as it must be — both images come off the same layers here
(measured: 146 lines, identical).
**The check that matters is between machines**, because `base` is built on each
one and `apt` resolves against whatever that machine's mirrors currently hold:
same Dockerfile, not necessarily the same package versions, and font package
versions are precisely what moves pixels. Carry the runner machine's output back
and diff it against this one's; a difference there is a screenshot diff waiting to
happen, and `docker save claudebox-base | ssh target docker load` settles it.

Package versions alone would not be enough, which is why the report also hashes
every font file. The DejaVu, Liberation and Noto files come from `ubuntu:24.04`
and are laid *over* Debian's packages, so `dpkg` reports Debian's version while
the bytes being rasterised are Ubuntu's — and the Arial/Verdana/Courier New that
CI copies in are cloned from `@main` and carry no package version at all. It also
records what fontconfig *resolves* (`rgba: 1`, `hintstyle`, which file each family
lands on), since that is the layer where Debian and Ubuntu differ by
configuration rather than by content.

### The trust boundary

The box gets no LAN access and no credential. `runner-relay` is on `inner` (where
the box reaches it) and on `edge` (where there is a route out), and it is the only
thing that holds `BOX_RUNNER`, `BOX_RUNNER_TOKEN` and `BOX_RUNNER_FINGERPRINT`.
It forwards exactly five routes — `/health`, `/sync/plan`, `/sync/delete`,
`/sync/upload`, `/exec` — and rebuilds the headers rather than passing them
through, so the box cannot set anything upstream sees except the body.

Identity is a **pinned certificate**, in two steps and in this order: a bare TLS
handshake that carries nothing is used to learn the runner's certificate and
check its fingerprint, and only a certificate that matched is then installed as
the sole trust anchor (`ca:`) for the requests that carry the token. Doing it as
`https.request` plus a `secureConnect` check would leave a window in which the
token could go to the wrong server; doing it by handing an already-connected
socket to `http.request` does not work at all (the request never reaches the
server and the client reports "socket hang up").

Self-signed rather than a CA because there is one client on one LAN, and mkcert
cannot help — its root lives on *this* machine, not the target. The consequence
is that **a rebuilt runner has a new certificate and must be re-joined**; the
relay says so by name when the fingerprint does not match.

#### Joining: the enrolment code

The token is 64 hex characters and the fingerprint 95, and the two together are
not a thing anyone types across a room correctly. So the join line carries an
eight-character code instead:

```
claudebox runner add 192.168.1.42:7998 hp3edhrp
```

`claudebox runner add` with two arguments runs `enrol.mjs` in a one-off container
from the relay image — the only thing here with both node and a route off this
machine, since the box has no LAN access by design and the host may have no node.
It learns the runner's certificate on a handshake that carries nothing, installs
it as the sole trust anchor, presents the code, receives the token, and writes
all three settings to `~/.claudebox/config`.

What that model does and does not protect, plainly:

- **It closes the attack worth closing.** The code is single-use and expires in
  15 minutes, so another host on the LAN cannot connect during the window and
  walk away with a token that grants it code execution on the runner. Ten wrong
  codes close the window rather than allowing unlimited guesses — a denial of
  service anyone on the network can trigger, which is the right trade: reopening
  is one command on the runner's console, and a window that closed by itself is
  a thing you want to notice. Every attempt is logged with its peer address.
- **The certificate is trusted on first sight.** An attacker already on the path
  at the moment of enrolment could present its own and keep MITMing thereafter.
  That is the residual risk `ssh` accepts the first time it shows you a host key,
  and it is why every request after enrolment is pinned rather than
  re-negotiated. `claudebox-runner join --full` prints the token and fingerprint
  explicitly for a join that accepts none of it; `claudebox runner add` still
  takes that three-argument form.

The window opens automatically only on a runner that has **never been joined** —
a runner that restarts nightly should not re-open one every night.
`claudebox-runner enrol` opens one deliberately: for a second agent machine, a
re-install on this side, or a window that expired before anyone got to it.

Be clear about what that boundary is and is not. `/exec` runs `bash -lc` on the
runner, so a box that can reach the relay has arbitrary code execution on the
runner machine as that user — deliberately, since that is the operation being
granted, and exactly as `ddev exec` through `ddev-relay` already grants a shell
in a project's web container. What the boundary buys is that the box holds no
credential and no route: it cannot reach *anything else* on the LAN, and
compromising it does not yield the token to use elsewhere. The runner is a
machine you are willing to hand to the agent, not a sandbox around it.

The path checks in `runner.mjs` are therefore about not corrupting the wrong
project by accident or by a malformed request — not about containing a hostile
client. They still all hold: a project or workdir that resolves outside its root
is refused rather than clamped, and `tar -x -C <project>` refuses members
containing `..` and strips leading `/`, so an upload cannot land outside the
project either.

### Sync

Source only, delta-transferred, in three calls: `POST /sync/plan` with a manifest
of `[path, size, mtime]`, then `/sync/delete` for what the runner has and this
side does not, then `/sync/upload` with a `tar` stream of what it needs.

Comparison is size + mtime — rsync's default quick check, and the reason the
upload is a tar rather than a file-by-file POST: tar preserves mtimes, so the
*next* sync sees unchanged files as unchanged instead of re-sending everything.

**What counts as source is decided on this side, by git.** A directory is left
out exactly when the project ignores it — never because of its name. Matomo
commits parts of `node_modules` and several plugins commit `vue/dist`; a name
list would silently drop those and leave the runner testing something subtly
different.

Asked once per repository, with `git status --porcelain -z --ignored`, which
collapses a wholly-ignored directory into a single `!! dir/` entry. One process
answers for the whole tree instead of a `check-ignore` per candidate, and that
is what makes it affordable to apply the rule to *every* directory rather than
to a shortlist of likely names — which matters, because the interesting cases
are not the obvious ones: `wp-matomo` ignores `wp/`, a whole WordPress install,
and a DDEV project ignores a dozen generated directories under `.ddev/`.
Directories only: an ignored *file* still goes, so nothing a checkout needs is
quietly withheld. The walk switches repository when it descends into a nested
checkout, so that project's own `.gitignore` is the one that applies inside it.

That last rule has a visible consequence worth knowing: a gitignored *file* is
overwritten on the runner by this machine's copy. For a DDEV project it happens
to be what you want — Matomo's `config/config.ini.php` says `host = "db"` on both
sides, and carrying the same salt and `trusted_hosts` across means the two
instances agree — but it does mean the runner cannot hold a machine-local
*file* that differs. Anything that must differ per machine belongs in an ignored
*directory*, or in the environment.

The client sends that exclusion list along with the manifest, and this is
load-bearing rather than an optimisation: without it the runner walks into its
own `vendor/`, sees files the manifest does not mention, and **deletes them** —
wiping the build output the runner exists to keep. The runner does not descend
into an excluded directory at all, and refuses a delete under one even if asked
directly. Everything the runner builds for itself therefore lives, by
construction, exactly where the sync does not look: `vendor/` from a composer
install run over there, `wp/` from a WordPress its DDEV project downloaded,
`.ddev/`'s generated configuration.

Measured here: `matomo` 46570 files in 31s first sync; `wp-matomo` 769 files in
0.3s once `wp/` is recognised as ignored (11510 and 5.4s before that). `.git` is
included by default (`--no-git` skips it) so the runner's tree is a real
checkout.

Build output never crosses the network. `composer install` / `npm ci` are run
once **on the runner** and stay there.

### In the box

```
runner status           what is joined, and which project/workdir this resolves to
runner sync             push this project's source
runner run <cmd...>     sync, then run <cmd> there (the usual one)
runner exec <cmd...>    run without syncing first
runner fetch <path...>  copy results back into this tree
```

A DDEV-backed suite is one line, because the runner has a real `ddev`:

```
runner run "ddev start -y && claudebox-ddev-bridge && ddev <the project's test command>"
```

A project is the nearest ancestor with `.ddev/config.yaml` or `.git`, climbing no
further than the workspace root — the same shape of check `ddev-relay` does. Both
the project and the workdir are sent *relative*, so the two machines need not
mount the tree at the same path, and both are re-resolved and re-checked against
the workspace root on the far side.

Output streams back frame by frame using the same `[1 byte channel][4 byte BE
length][payload]` framing `ddev-relay` uses (1 stdout, 2 stderr, 3 meta JSON), and
the exit code is the remote command's.

### DDEV on the runner

DDEV runs **inside the runner container**, driving the runner's own rootless
dind. `ddev` is a Docker client, so pointing `DOCKER_HOST` at the sidecar is the
whole of it: every project container it starts lives in there.

The runner image takes `ddev`, `ddev-hostname` and `mkcert` out of one pinned
DDEV release tarball. Three things had to be true before `ddev start` worked,
and each failed in its own way:

| | |
|---|---|
| `ddev-hostname` must be present | `ddev start` shells out to it and fails hard: *"Binary not found: ddev-hostname is not installed"*. It ships in the same tarball. |
| It must be able to elevate | It checks its own euid rather than whether it can write the file, so making `/etc/hosts` writable does not satisfy it. The image installs `sudo` with **one** rule: `NOPASSWD: /usr/local/bin/ddev-hostname`. |
| `router_bind_all_interfaces: true` | Project ports are published on the *daemon's* interface, and the daemon is a different container. Bound to `127.0.0.1` (the default) they are reachable only from inside the sidecar, and every request to a project is refused in a way that looks like the project failing to start. |

DDEV's install script is not usable in a Dockerfile — it refuses to run as root,
which is what a `RUN` is — so the tarball is fetched and verified against the
release's `checksums.txt` instead. There is no `ddev version` smoke test in the
build: every ddev subcommand connects to a daemon first, and there is none
during a build.

**mkcert.** The box trusts the *host's* mkcert root, because the projects it
talks to are started by that host. The runner starts its own, so there is no
other root to agree with: `entrypoint.sh` generates one into the persistent HOME
volume on first start, installs it into the system store on every start (the
store is an image layer, the CA is a volume), and `NODE_EXTRA_CA_CERTS` points
at the same file. `https://<project>.ddev.site` from the runner verifies.

**The HOME volume is mounted into the sidecar too**, at the same path, and that
is not optional: `ddev start` binds several things out of `~/.ddev` into the
containers it creates — `homeadditions`, and the directory it pushes the mkcert
root out of — and those binds are resolved by the sidecar's daemon. A bind
source that does not exist there is not an error; Docker silently creates an
empty directory, so the certificates would simply never arrive.

#### How the database and the hostnames are reached

The plan left this open, because the box's answer does not port: `ddev-db` is a
compose service that socats to a *sibling* container, and here the project's
containers are a level down inside the sidecar where no sibling can see them.

What reaches into that level is port publishing, so the sidecar has a **fixed
address** (`10.99.2.10`) on the runner network and everything published inside
it is reachable there:

```
https://<project>.ddev.site  ->  10.99.2.10:443   ->  ddev-router  ->  web
db:3306                      ->  10.99.2.10:3306  ->  a socat container started
                                                      INSIDE the sidecar
                                                      -> ddev-<project>-db:3306
```

`claudebox-ddev-bridge` (in the runner image, run from a project directory) sets
both up:

- **The database.** DDEV publishes it on a port it picks per start, which is no
  use to a config file that says `host = "db"`. So the bridge starts a forwarder
  on a fixed port with **one hard-coded destination** — the same constraint the
  box's `ddev-db` has, and for the same reason: one that took its target from
  the request would be a general TCP proxy into the sidecar's network. The
  runner's `extra_hosts` maps `db` to the sidecar, so `db:3306` from the runner
  means what it means in the box.
- **The hostnames.** `*.ddev.site` resolves to `127.0.0.1` in public DNS, which
  in the runner container is the runner. `ddev start` writes the right entries
  itself — it aims them at the *daemon's* address, which is already the sidecar —
  but `/etc/hosts` is container-local and Docker writes a fresh one on every
  start, so **a runner container recreate leaves them behind** even though the
  projects inside the sidecar are untouched. The bridge repairs that with DDEV's
  own `ddev-hostname`, which is what the one sudo rule is for.

Run `ddev start -y && claudebox-ddev-bridge` together, always. Restarting the
runner stops the sidecar and therefore every project inside it — DDEV's
containers carry no restart policy, so they do not come back on their own — and
it also discards the runner's `/etc/hosts`. Both halves of that are what the one
pair of commands fixes, which is why the bridge refuses with those exact
commands rather than trying to guess.

`claudebox-ddev-fixups` ports unchanged: it drives `ddev exec`, which on the
runner is the real thing rather than the box's shim onto the host.

#### The CI-shaped addresses: host.docker.internal and localhost:8888

Matomo's UI suite is written against a single-host CI runner, and two addresses
in it are load-bearing:

```js
const baseUrl = process.env.UITEST_WP_ENV_BASE_URL || 'http://localhost:8888';
await page.webpage.goto('http://host.docker.internal/tests/PHPUnit/proxy/index.php?...');
```

`localhost:8888` is wp-env's WordPress and `http://host.docker.internal/` is
Matomo — **on port 80**, which is why the DDEV router's plain-HTTP port is moved
out of the way rather than the front door being put somewhere convenient. A port
suffix would appear in URLs the screenshots contain.

**`localhost:8888`** is the box's `CLAUDEBOX_DIND_PORTS` forwarders, ported to
`runner/entrypoint.sh` unchanged: a container started inside the sidecar
publishes onto the *sidecar's* interface, so wp-env's WordPress is at `dind:8888`
and a spec that says `localhost:8888` finds nothing. Chromium runs in the runner
container, so that is the side that has to agree with the baseline.

**`host.docker.internal`** is the box's `ddev-http`, moved a level down — and the
move is what makes it interesting. In the box it is a sibling compose service at
a fixed address on `claudebox_inner`. On the runner it cannot be a sibling: the
project's containers live inside the sidecar, and a sibling could only reach them
through published ports, which means through `ddev-router` — and traefik replaces
`X-Real-Ip`/`X-Forwarded-For` with the address it received the connection from
unless that peer is in its trusted list. The whole point of the front door is
that those headers are *ours* to set.

Nor can the runner create siblings: it drives the sidecar's daemon and has no
access to this machine's, by design. So the front door runs **inside** the
sidecar, started by `claudebox-ddev-bridge` on the project's own network, where
it reaches `ddev-<project>-web` by name.

Three consequences, each of which cost a round to find:

| | |
|---|---|
| `--host-gateway-ip=10.99.2.10` | The sidecar's own address on the runner network, so `host.docker.internal:host-gateway` — which wp-env attaches to everything it starts — lands on whatever the sidecar publishes. `extra_hosts` gives the runner container the same name, because Chromium runs there. |
| `router_http_port: "8080"` | Port 80 inside the sidecar belongs to the front door. The router keeps 443, so `https://<project>.ddev.site` is unchanged. |
| a passthrough server block | Without it, `http://<project>.ddev.site` would quietly reach the *one* project the front door points at — a wrong answer that looks like a right one. nginx prefers an exact `server_name` over a regex, so `host.docker.internal` keeps the front door and `*.ddev.site` goes to the router. It must name the router's **configured** port: moving the published port moves traefik's entrypoint with it. |

The nginx configuration is the *same file* the box's `ddev-http` image is built
from — shipped into the runner image as a template, rendered by the bridge with
`sed`, and handed to a stock `nginx:alpine` over a bind mount. Not built as an
image, because a container inside the sidecar cannot see images built out here
and there is no registry to pull a local one from. Sharing the file is the point:
what is in it (the `Host` rewrite, `X-Real-IP: 127.0.0.1`) is exactly the part
that would show up as screenshot diffs if the two copies drifted.

Measured on the runner, which is the check worth repeating after any change here:

```
via host.docker.internal : 127.0.0.1|matomo.ddev.site
via https router         : 172.28.1.1|matomo.ddev.site
```

The first line is what a CI runner records. The second is why the front door is
not simply the router.

And from inside a container wp-env started, which is the path that has to work
for the WordPress side of the suite:

```
$ getent hosts host.docker.internal
10.99.2.10      host.docker.internal
$ curl -o /dev/null -w '%{http_code}' http://host.docker.internal/tests/PHPUnit/proxy/index.php
200
```

#### Where UI testing actually stands

The infrastructure is verified end to end, and **rendering parity is proven**.
`WordPress_Plugin_wp_installed.png` compared clean against a baseline recorded on
an `ubuntu-24.04` CI runner. Better evidence still came from one that did *not*
compare clean: stacking `WordPress_Plugin_wp_admin.png` against its baseline shows
the two pages pixel-identical — same glyphs, same wrap points, same shades —
except for a URL string reading `matomo.ddev.site` where the baseline reads
`host.docker.internal`. An 11403-pixel diff that is entirely one line of *text
content* is exactly what a correct font stack looks like; a font mismatch moves
every glyph on the page.

The suite as a whole does not pass yet, and none of the remaining causes is the
runner:

- **The nested-uid write permission** above, which blocks the plugin install and
  is measurably identical in the box.
- **WooCommerce onboarding drift.** `.wp-env.json` pulls
  `downloads.wordpress.org/plugin/woocommerce.zip` — always the latest — and the
  spec's "skip setup" step no longer finds its link (`cannot find skip setup
  link`, then `Execution context was destroyed`). That is the project's pin to
  fix, and it would fail the same way here.
- **The Matomo instance's own recorded URL.** A Matomo installed on the runner by
  `ddev matomo:init` knows itself as `matomo.ddev.site`, and the plugin's settings
  page prints that URL where the baseline has `host.docker.internal` — which is
  the entire 11403-pixel diff above. The fix is `UITEST_MATOMO_BASE_URL` in
  `plugins/WooCommerceAnalytics/.env`, which the fixture reads; the file is
  gitignored, and gitignored *files* do cross, so writing it on this machine puts
  it on the runner. (`tests:run-ui --matomo-domain=...` looks like the tidier
  answer and is not: it is forwarded to `tests:setup-fixture`, which does not
  accept it, and the fixture then fails to set up at all.) Setup state, not
  environment.

So: proven that the runner can render a baseline-identical screenshot; not yet
proven that this particular suite is green anywhere.

#### Artifacts

`GET /artifacts?project=&path=` returns a tar of one path; `runner fetch <path>`
extracts it into the local tree.

The plan asked whether it should return everything or only diffs. Neither: **the
caller names the path**. The runner has no idea what an artifact is, and a rule
baked in at either end (`only diffs`, `everything under tests/`) would be wrong
for the next suite. `runner fetch tests/UI/screenshot-diffs` needs no convention
to read.

It extracts over what is there and removes nothing — a result being copied back,
not a tree being kept in step. The path is validated against the project root the
same way every other path is, and the size is checked *before* streaming rather
than cut off mid-tar: a truncated tar fails with an error about the archive,
which is a poor way to learn that a UI failure produced four thousand
screenshots. `CLAUDEBOX_RUNNER_MAX_ARTIFACT` (2 GB) is the ceiling.

#### The one environment difference: DDEV containers run as root

On a **rootless** Docker daemon, DDEV runs its containers as root — container
root maps to the unprivileged user outside, so files in the tree still come out
owned correctly, and this is DDEV's documented behaviour rather than a
misconfiguration. It is not configurable: `DDEV_UID`/`DDEV_GID` in the
environment do not change it.

The box's DDEV projects run on the host's **rootful** daemon, where DDEV uses
uid 1000. So this is a genuine divergence between the two, and it surfaces as
tools that refuse to be root. The one that shows up immediately:

```
If you'd like to continue as root, please run this again, adding this flag: --allow-root
```

— wp-cli, invoked from `wp-matomo`'s test harness. Nothing about rendering or
file ownership is affected, and CI runners generally run as root too, so for
baseline fidelity this is arguably the closer match. The alternative is a
**rootful** dind on the runner, which means `--privileged`: on a machine the box
already has arbitrary code execution on, that turns container escape into root
on the runner machine itself. Rootless is the deliberate choice; the difference
is documented rather than designed away.

### Setting up a runner machine

```
git clone <this repo> ~/.claudebox && ln -s ~/.claudebox/claudebox-runner ~/.local/bin/
claudebox-runner                      # builds base, builds the runner, starts it
                                      # and prints the join line
```

Then on this machine, paste the line it printed:

```
claudebox runner add 192.168.1.42:7998 <code>   # the 8 characters it printed
claudebox                                       # relaunch to pick it up
```

The runner's identity lives in the `claudebox-runner-state` volume, so restarts
and rebuilds of the *service* keep it. `claudebox-runner reset` deletes the synced
workspace (costing a re-sync) and keeps the identity.

#### First run for a project

Nothing gitignored is synced, which is the whole design — and it means every
`node_modules` and `vendor` has to be installed *on the runner*, once. It is
worth knowing how many there are before hunting the third one: Matomo's UI suite
needs **three separate installs**, and each failure names something else.

```
runner exec "composer install"                                 # vendor/
runner exec "npm ci"                                           # node_modules/
runner exec "cd tests/lib/screenshot-testing && npm ci"         # Cannot find module 'puppeteer'
runner exec "cd plugins/WooCommerceAnalytics && npm install"    # sh: 1: wp-env: not found
```

Then, per session:

```
runner run "ddev start -y && claudebox-ddev-bridge && claudebox-ddev-fixups"
runner exec "WP_ENV_HOME=/home/dizzy/Projects/.wp-env-home \
  php console tests:run-ui --plugin=WooCommerceAnalytics --keep-symlinks WordPress_Plugin"
runner fetch plugins/WooCommerceAnalytics/tests/UI/processed-screenshots \
              plugins/WooCommerceAnalytics/tests/UI/screenshot-diffs
```

`WP_ENV_HOME` must be a path the sidecar can see. Under the workspace is the
obvious one and matches what this machine needs. On the runner the default
`~/.wp-env` would work too — HOME is mounted into the sidecar for DDEV's sake, and
a bind out of it resolves (checked) — but keeping the same value on both machines
is one less difference.

### Protocol

| Operation | Purpose |
|---|---|
| `POST /sync/plan` | manifest in, `{need, delete}` out |
| `POST /sync/delete` | remove what this side no longer has |
| `POST /sync/upload` | a tar of what it needs |
| `POST /exec` | run a command, framed output back |
| `GET /artifacts` | tar one path back |
| `POST /enrol` | trade a one-time code for the token — **the one route with no token check**, because it is where the token comes from |

`runner-relay` forwards the first five and rebuilds the headers rather than
passing them through. `/enrol` is not forwarded: it is spoken once, at join time,
by a one-off container and never by the box.

## Seeing what a session is doing, and stopping it

A headless run is silent by construction: `claude -p` is print mode, so it emits
its answer when it finishes and nothing before. A session that is thinking hard
and one that is wedged look identical from outside — and when the run was
forwarded through the agent door, the person who started it is on another
machine with no process of their own to look at.

```
$ claudebox ps

pid 2047    04:07     looker-studio-connector      headless, via the agent door
  doing:  npx jest --config=./jest.config.unit.ts
  prompt: Below is a description of a possible bug or vulnerability. please read it,...
```

Everything it prints is read out of the box's `/proc` through one `exec`;
nothing is recorded anywhere while a session runs, because the process table
*is* the state. Three details are load-bearing:

- **`/proc/<pid>/cwd` is read as the box user, not root.** It is readable only
  by the process owner or with `CAP_SYS_PTRACE`, and the box drops that — so
  root gets "permission denied" here while the user the session runs as reads it
  fine.
- **`doing:` shows what claude's Bash tool `eval`'d**, not the wrapper around
  it. Every such command begins with a hundred characters of sourcing a shell
  snapshot and unsetting things, which is identical every time; without
  stripping it the line is all preamble and the command is off the end.
- **A session whose parent is `agent-serve.mjs` came through the door.**
  Anything else was started here. That is the whole of how origin is decided —
  no bookkeeping, just the parent pid.

`claudebox kill` stops one. A headless run has no terminal to interrupt —
nobody is holding it — and one that arrived through the agent door cannot be
stopped from the machine that asked for it once that machine has walked away.
With a single session running it needs no pid; otherwise it takes one from `ps`,
or `--all`.

It refuses a pid that is not a session, so it cannot be used to signal arbitrary
processes in the box. It asks (TERM) before insisting (KILL), because claude
writes state as it exits and a KILL that arrives first leaves that half written.
And it **collects the session's descendants before signalling** — once claude is
gone its children are reparented to pid 1 and nothing can identify them any
more, which is how a test suite or a language server survives a naive kill.
Stopping a forwarded session works from here too: the machine that sent it sees
the run end with 143.

`jira:triage-issue` prints a `still running (2m30s)` line every thirty seconds
while it waits, for the same reason: the cheapest thing that distinguishes a
long run from a dead one. Interrupting it stops the session rather than just
stopping the wait — it kills the process group, which for a forwarded run drops
the connection and lets `agent-serve.mjs` kill its child, and for a local run
also finds the session in the box by the issue key in its prompt, since
`docker exec` does not pass a signal to the process it started.

## The agent door: keeping claude off a runner machine

A runner is the box **minus the agent**, and its network is an ordinary bridge
with no proxy and no allowlist — it has to reach package registries to build
what it tests. That makes it the wrong machine to run an agent on, in a
container or otherwise. Nothing used to stop someone typing `claudebox` there.

Now, on a machine where the `claudebox-runner` container is running:

| | |
|---|---|
| `claudebox -p '...'` | sent to the workstation that was joined, and answered in **its** box |
| `claudebox <plugin>:<cmd>`, `claudebox plugins` | run here, normally |
| everything else | refuses, and says where to go instead |
| `claudebox agent ...`, `claudebox mutagen ...`, `claudebox help` | still work — the first is how the machine is pointed at a workstation at all, and the second is a door and a file copier rather than a session |

**`claudebox mutagen` runs on the runner machine too.** What this gate is for is
keeping an *agent* off it; serving this machine's workspace on the LAN, or
keeping a copy of another machine's, starts no claude and no box. It was being refused
with "this machine hosts a runner, so it is not where the agent runs" — true,
and nothing to do with the command. Note what the door does **not** offer to
serve there: the runner's tree lives in a named volume and is a *sync target*
that `runner run` overwrites from the workstation, so sharing it would hand
someone a copy that is rewritten under them. The door serves that machine's own
`BOX_WORKSPACE_HOST`, as everywhere else, and says so if there is no tree there.

**Plugins run on the runner machine**, and `jira:triage-issue` is why: it fetches
an issue with a credential that lives *there* and then asks for a headless run,
which this forwards. Refusing it would mean the plugin could only be run on the
machine that does not have its credential.

That only works because a prompt carries its content rather than a path. A
plugin's files land on the runner machine while the session that answers runs on
the workstation, so anything a plugin names in a prompt has to be text it sent,
not a path it wrote. `runner_hosted_here` in `plugin-api.sh` is how a plugin asks
which side it is on; `jira:triage-issue`'s size fallback is the one place that
has to — over ~100KB it truncates and says so, rather than naming a file that
exists on the wrong machine.

Detection is about what is **running**, not what is configured: a stopped runner
stack is not a runner, and a machine that has merely *joined* one is a
workstation.

```
  the runner machine                          the workstation
  ------------------                          ---------------
  claudebox -p '...'
    │ hosts a runner -> does not run one
    ▼
  send.mjs ──TLS + token + pinned cert──▶ agent-relay        (edge + inner)
  (one-off container)                       │  published :7996
                                            │  plain HTTP over inner
                                            ▼
                                          agent-serve.mjs    (inner only)
                                            │  in the box, as the box user
                                            ▼
                                          claude -p, cwd = the named project
```

**Two containers, not one**, for the same reason `runner-relay` is separate from
the box: the relay is the only thing with a LAN-facing socket. The box gets no
listener anything on the LAN can reach and opens no connection to one — it is
spoken to over `inner`, which is `internal: true`. Publishing `agent-serve`'s
port directly would be simpler and would put an inbound LAN socket in the box;
the line that binds it says so.

`runner-relay` and `agent-relay` are the same shape pointed in opposite
directions: one is **outbound** and holds a credential for a machine elsewhere,
the other is **inbound** and holds an identity that a machine elsewhere pins.
Enrolment, the short code, the failure counter, the two-step pin and the
`[1 byte channel][4 byte BE length][payload]` framing are all the runner's,
reused rather than reinvented.

**Off by default.** `BOX_AGENT_SERVE=1` is the only thing that turns it on: the
service sits behind a compose profile the launcher enables only for that
setting, and `entrypoint.sh` starts the in-box listener only when it sees the
matching variable. A claudebox that does not use this creates no container and
publishes no port.

### Setting it up

```sh
# On the workstation -- the machine that runs the agent.
# One command: sets BOX_AGENT_SERVE=1, brings the box and the front door up,
# reports, and opens an enrolment window with the code to type over there.
claudebox agent start

# On the runner machine
claudebox agent add <workstation>:7996 <code>
claudebox agent test
```

`agent start` is also how to bring the door back up after a restart — it is
idempotent, and on a machine that is already joined it says so rather than
opening a window nobody asked for. `claudebox agent enrol` opens one
deliberately, to join a second machine.

`claudebox agent stop` is the pair: front door down, setting cleared, box
restarted without its listener. It **keeps the identity** — that lives in the
`agent-state` volume, and re-issuing it would break the pin every joined machine
holds, so all of them would have to re-join. Turning the door off for an
afternoon should not cost that; `docker volume rm claudebox_agent-state` is how
you ask for a new identity on purpose.

`agent-serve.mjs` is baked into the box image, so a claudebox that predates it
needs a rebuild before `agent start` will produce a working door.

### Which project

A forwarded prompt usually names files, and the two machines have separate
trees — that is why `runner sync` exists. The request carries a **project
name**, one directory under the workspace: `--project <name>`, or the directory
the current one sits in below `BOX_WORKSPACE_HOST`. The workstation resolves it
under its own `BOX_WORKSPACE` and **refuses if it is not there**, naming the path
it looked in. There is no reverse sync; the tree is expected to be on both
machines, the same way it already is for tests.

### What presenting the token gets you

A `claude` process in the workstation's box, in a project of its workspace, with
whatever flags were sent — the mirror of the bargain `runner.mjs`'s `/exec`
already makes in the other direction, and it is the operation being granted
rather than a leak. It is bounded by the box being the box: same allowlist, same
proxy, same workspace, same HOME. It is **not** bounded by the flags, so the
token is a real credential: it lives in `~/.claudebox/config` on the runner
machine at `0600`, goes to a one-off container and nowhere else, and is passed
to that container **on stdin** — NUL-separated, along with the prompt — because
process arguments are readable by every process on the machine and
`docker run -e TOKEN=...` would put it in the docker client's own command line.

## Sharing the workspace between machines

Two machines, one source tree. `claudebox mutagen start` on the machine that has
the tree brings up `claudebox-sync` — an sshd over the *same bind the box gets* —
and publishes it on the LAN. `claudebox mutagen attach <host>` on the other
machine keeps a **live local copy** of that tree in step with it and points
`BOX_WORKSPACE_HOST` at the copy, so claudebox there runs against real local
files while the box still sees a plain `~/Projects`.

### Why a copy and not a mount

This replaced an sshfs mount, and the reason is git. `git status` does one
`lstat` per tracked file plus a `readdir` per directory; on a network filesystem
every cache miss is a round trip, so a 30k-file repo is tens of thousands of
round trips before git has read a single object. No tuning fixes it — git is
*designed* to walk the whole tree, which is why it is slow on any network
filesystem.

Measured here, same 3,004-file repo, same machine, same door, over **loopback** —
which is the best case sshfs can possibly have, with no network latency at all:

| | sshfs | mutagen copy |
|---|---|---|
| `git status`, cold | 2.046s | 0.014s |
| `git status`, warm | 0.068s | 0.013s |

On a real LAN the cold number gets worse in proportion to round-trip time; the
copy's does not change, because nothing about it crosses a network. That is the
whole argument.

```
  this machine (runs claude)                    the other machine (holds the tree)
  ┌──────────────────────────────┐              ┌──────────────────────────────┐
  │ claudebox-mutagen  (edge)    │              │  claudebox-sync   (edge)     │
  │   mutagen daemon run         │─── LAN ─────▶│    sshd, keys only           │
  │   as ${BOX_UID}:${BOX_GID}   │   :7994      │    HOME on sync-state vol    │
  │        │                     │              │      └ .mutagen/agents/…     │
  │   ~/.claudebox/              │              │         (copied in by us)    │
  │     synced-workspace  ◀──────┼── sync ──────┼──▶ ${BOX_WORKSPACE} (bind)   │
  └────────┼─────────────────────┘              └──────────────────────────────┘
           │ BOX_WORKSPACE_HOST
           ▼
     claudebox / dind / ddev-relay   ← ordinary bind of a real local directory
```

### The two halves

| On the machine that HAS the tree | On the machine that borrows it |
|---|---|
| `claudebox mutagen start` — bring the door up and publish it (`BOX_SYNC_PORT`, default 7994) | `claudebox mutagen attach [user@]<host>[:port]` — start syncing and work in the copy |
| `claudebox mutagen authorize '<key>'` — let a machine in | `claudebox mutagen detach` — stop syncing, restore the local workspace |
| `claudebox mutagen status` — up? fingerprint? who may log in? | `claudebox mutagen status [--follow]` — connected? current? conflicts? |
| `claudebox mutagen stop` — stop serving; identity kept | `claudebox mutagen resolve --local\|--remote`, `claudebox mutagen forget [--purge]` |

Joining is `ssh-copy-id` by hand, in the two commands it takes:

```
B$ claudebox mutagen attach 10.0.0.49:7994    # prints B's public key, refuses
A$ claudebox mutagen authorize 'ssh-ed25519 AAAA... claudebox@B'
B$ claudebox mutagen attach 10.0.0.49:7994    # seeds the copy, pins A's host key
```

`sync` is accepted as an alias for `mutagen` throughout — the service, container,
volume and directory are all called sync; mutagen is the tool that does the work.

### Mutagen runs only in containers, on both ends

Neither host has mutagen installed, and that is not merely hygiene.

**Mutagen accepts no per-session ssh options.** It shells out to the system
`ssh`/`scp`, and the identity file, port and known-hosts file must come from an
ssh config file — the only one it reads being `$HOME/.ssh/config` for whoever it
runs as. On the host that is the *user's own* ssh config, which claudebox has no
business writing to. In the sidecar, `$HOME` is ours: the config is generated
from scratch on every start (`mutagen-client/entrypoint.sh`) and points at
claudebox's own key and its own pinned `known_hosts`. Nothing under `~/.ssh` is
read or written.

**The far end needs nothing installed either.** Mutagen `scp`s an agent binary
into the door container and runs it over ssh. Two consequences worth stating:
the agent is copied *from the local sidecar*, so the two ends can never be
version-skewed; and the door's login user needs a writable home, which is why
that home moved off the workspace (below).

**The borrowing machine needs no host tooling at all** — no mutagen, no sshfs,
no FUSE, no `user_allow_other`, not even ssh. `ssh-keyscan`, `ssh` and the
fingerprint checks all run inside the sidecar via `docker exec`.

### Load-bearing decisions

- **The login user's home is NOT the workspace, and this reverses the sshfs
  design.** Under sshfs the home *was* the tree, so `sshfs host:` needed no
  path. Mutagen installs its agent at `$HOME/.mutagen/agents/<version>/`, so
  that arrangement would put a ~20MB binary **inside the source tree** and then
  sync it out to every machine attached to it, forever, as a file nobody put
  there. The home is now `${STATE}/home/<user>` on the state volume: writable,
  persistent (so the agent is copied once, not per reconnect), and outside
  anything anyone syncs. The served path is published instead, in
  `${STATE}/served-workspace`, and the client reads it over ssh with
  `claudebox-sync-info` rather than guessing that both machines use the same
  `BOX_WORKSPACE`.

- **`StrictModes` went back on** as a direct consequence. It was off because the
  home was a bind of the host's tree, whose 0775 mode made sshd refuse every
  login; the home is now 0700 and ours, so the check costs nothing and is
  restored.

- **The empty-alpha hazard, and three guards against it.** This is the danger
  the sshfs version did not have. `two-way-safe` does **not** treat "deleted
  here, unmodified there" as a conflict — it is an unambiguous delete. So once a
  session exists, a local copy that goes missing or is recreated empty
  propagates **deletions into the other machine's source tree**. The realistic
  way to get there is `BOX_SYNC_DIR` on a drive that did not mount. Three
  independent defences:
  1. **A sentinel** (`.claudebox-sync-root`) written into the copy at attach and
     in the ignore list, so it never crosses. It can only exist because attach
     put it there, so its absence is unambiguous, and `require_workspace`
     refuses on it before the box starts.
  2. **The door refuses to serve an empty tree** (`sync-server/entrypoint.sh`) —
     the same hazard seen from the other end, where serving nothing would tell
     the attached machine that everything was deleted.
  3. **The copy is bound at the same path inside the container as outside.**
     Mutagen stores the session's alpha path; with a fixed `/workspace`,
     changing `BOX_SYNC_DIR` would silently re-point a live session at a
     *different* host tree. With identical paths the session instead fails to
     find its root — a failure rather than a catastrophe.

  Mutagen has its own backstop too (`halted-on-root-emptied`), and the guard
  reports it rather than working around it.

- **`.git` IS synced — do not add `--ignore-vcs`.** It is the obvious flag,
  every mutagen example uses it, and it is exactly wrong here: it would leave
  `.git` out of the copy, so `git status` in the box would answer "not a git
  repository". Git running locally is the entire reason this replaced sshfs, and
  that requires `.git` to be local. The comment at the call site says so, because
  this is the thing a maintainer will reach for.

  The cost, which nothing enforces: **do not run git in the served tree on the
  other machine while a session is attached.** Two gits writing one `.git`
  through a reconciler that does not understand packfile atomicity will corrupt
  a repository. It is in `config.example` and in the door's own `status` output.

- **A stale copy is worse than a missing one, so the launch guard proves
  liveness rather than inspecting the directory.** The sshfs guard could ask
  "is anything mounted"; a synced copy that stopped syncing is a directory full
  of plausible source code. Every failure — daemon dead, container gone, session
  paused, remote unreachable, conflicts halting propagation — produces that same
  appearance. So `sync_require_current` asks the syncer to prove the copy is
  current *right now*, and fails closed when it cannot:
  fatal on a missing sentinel, a missing syncer, a session against a different
  tree, no session, paused, halted, conflicts, or a flush that does not complete;
  a loud **warning** (not a refusal) when the remote is merely unreachable but
  the copy has synced, because working offline is legitimate.

- **Connectivity is checked before the cycle count.** A session that was paused
  and resumed, or that reconnected, restarts `SuccessfulCycles` at zero. Reading
  "0 cycles" as "the first sync never finished" mis-diagnoses a healthy session
  that has just come back, and buries the real answer when the remote is down.

- **`--symlink-mode=posix-raw`.** The default (`portable`) accepts only relative
  links that stay inside the sync root, and real trees carry absolute ones in
  `node_modules` and `vendor`. Mutagen does not *follow* symlinks, so a link
  pointing outside the tree is still just a link, not a traversal.

- **No default ignores.** Ignoring dependency trees is the main tuning lever and
  the obvious footgun — a test run that needs `vendor/` finds it missing. Ship
  `BOX_SYNC_IGNORE` empty and documented; `claudebox strip` is the other half of
  the answer. It uses `${VAR-default}`, not `${VAR:-default}`, so an explicitly
  empty setting stays empty.

- **`mutagen sync flush` blocks until a cycle completes, and hangs forever
  against a disconnected endpoint.** So it is never what waits for the initial
  seed (polling `sync list` is), and every call is wrapped in `timeout` **inside
  the container** — a host-side timeout around `docker exec` kills only the
  client and leaves mutagen waiting.

- **`detach` stops the box only if the box is actually in the copy.** The reason
  to stop it is that anything written between the flush and the session ending
  exists on one machine and nothing carries it over. That reasoning applies only
  to a box working in the copy; a box working elsewhere is a live session with a
  person attached to it, and killing that to tidy up a sync it is not using
  would be gratuitous.

### Traps found while building it

- **`--template` renders Go struct fields, but `{{json .}}` prints protobuf json
  tags, and they are not the same names.** Probing with
  `mutagen sync list --template '{{json .}}'` shows `status`, `paused`,
  `successfulCycles`, `alpha.connected` — and a template written from that
  output fails with `can't evaluate field status in type
  synchronization.Session`. The real names are capitalised: `.Status`,
  `.Paused`, `.SuccessfulCycles`, `.Alpha.Connected`, `.Beta.Connected`,
  `.Conflicts`. `.Status` also renders the enum's `String()`, so it reads
  `Watching`, not `watching` — hence case-insensitive matching wherever it is
  compared. A health check built on the wrong names renders empty for every
  field and reports healthy forever, which is exactly the failure the guard
  exists to prevent.

- **From the syncer, `127.0.0.1` is the syncer.** The obvious way to test the
  feature on one machine is to attach to its own door at `127.0.0.1:7994`, and
  the syncer is a *container*, so loopback there is the container itself and the
  door published on the host's port is not on it. It failed as "nothing
  answered", which names the wrong problem entirely. `attach` now recognises a
  loopback address and prints the LAN addresses to use instead.

- **A keys-only account is a *locked* account, and sshd without PAM refuses
  it.** `adduser -D` leaves `!` in the password field, which every keys-only
  account on an ordinary distro carries — they work because their sshd runs
  `UsePAM yes`, which skips the locked-account check. Alpine's sshd has no PAM
  and does the check itself: `User dizzy not allowed because account is locked`,
  before the key is ever read. The entrypoint gives the account 32 unusable
  random bytes instead — not the same as unlocking it with an *empty* password,
  which would leave `PermitEmptyPasswords` as the only thing standing there.

- **`openssh-server` does not pull in `openssh-sftp-server`**, and scp on a
  modern client is SFTP underneath — which is how mutagen installs its agent.
  Without it, ssh logins work perfectly and the agent copy fails at `subsystem
  request failed on channel 0`.

- **`docker inspect <name>` answers about images too.** `sync_serving` must be
  `docker inspect --type container -f '{{.State.Running}}'`; the bare form
  returns success on any machine that has merely *built* the image, so the door
  reports itself up with no container anywhere.

- **`set -euo pipefail` makes a failed pipeline inside `x="$(a | b)"` end the
  launcher, silently** — no message, no exit code anyone sees. Every such
  substitution here ends in `|| true` and lets the code below decide what an
  empty value means.

- **The loopback deadlock that sshfs had is gone, and the refusal that guarded
  it is not needed any more.** Under sshfs, the mount and the sshd serving it
  were services in one compose project: the next launch recreated the door while
  the host's own mount was live, the mount blocked forever (it was mounted
  `-o reconnect`), dockerd blocked in the kernel resolving the bind source, and
  the machine needed a reboot. None of that mechanism survives — the copy and
  the served tree are two ordinary directories and mutagen never blocks on
  either. Attaching to this machine's own door is now the supported way to test
  the feature without a second machine, with one check that still bites: the two
  trees must not overlap, which would be a sync into itself.

### What this is not

It is not a way into the box. `claudebox-sync` forwards nothing
(`AllowTcpForwarding no`, no agent forwarding, no tunnels), has no route to
`inner`, and serves one directory. `claudebox-mutagen` is on `edge` alone too,
and deliberately never joins `inner` — it holds an ssh private key that another
machine's door trusts, and `inner` is where the relays holding this machine's
runner and agent tokens live. Running claude over the tree still happens in each
machine's own box, under its own allowlist.

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
`*.woocommerce.com`, `*.packagist.org`, `getcomposer.org`, and for opencode
`opencode.ai`, `*.opencode.ai`, `models.dev`.

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

### Open: nested containers cannot write to the workspace as a non-root user

**This affects the box, not only the runner**, and it arrived with the move off
Docker Desktop rather than with any change here.

Under rootless dind, rootlesskit maps *nested* root to the daemon's user, so a
tree owned by uid 1000 outside appears as **uid 0** inside a nested container. A
nested process running as uid 1000 — which is what wp-env runs Apache as — then
cannot write to it. Measured identically on both machines:

```
$ docker run --rm -v ~/Projects/matomo/wp-uploads:/w -u 1000:1000 alpine \
    sh -c 'ls -ldn /w; touch /w/probe'
drwxr-xr-x 5 0 0 4096 /w
touch: /w/probe: Permission denied      # as root: writable
```

Docker Desktop's virtiofsd squashed every uid to 1000, so this could not happen
there; a native `dockerd` passes ownership through. The last successful UI run on
this machine predates that switch.

What it looks like when you hit it, and why it is worth naming: the suite runs,
the fixture sets up, Chromium drives the browser, and the failure is a WordPress
page reading

```
The uploaded file could not be moved to wp-content/uploads/2026/08.
```

— which reads like a WordPress or wp-env problem and is neither.

It is not only the directories the fixture maps in (`wp-uploads`,
`wp-debug.log`). wp-env's own WordPress tree under `WP_ENV_HOME` has the same
problem — WordPress needs `wp-content/upgrade` to unpack a plugin, and that is
created by wp-env as the outer user and therefore shows as uid 0 inside too. The
first symptom is the upload; the next one, once that is fixed, is

```
Could not create directory. /var/www/html/wp-content/upgrade
```

so fixing them one at a time is a trap. Everything the containers write into has
to be writable by the nested uid.

Making those trees world-writable is the small fix; running wp-env's containers
as root is the other. Neither is chosen here — it is the *project's* fixture that
creates those directories, and which answer is right depends on what else writes
into that tree.

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

- **On a native engine, ownership in the binds is real — and root writes stay
  root.** Docker Desktop ran virtiofsd with `--translate-uid squash-guest:0:1000`,
  which mapped every uid to yours in both directions: host files always read as
  1000 in a container, and anything a container's root wrote came back owned by
  you. That is what made the caveat above a caveat. A native `dockerd` does no
  translation, so a root process in a container leaves root-owned files in the
  tree that the box, running as 1000, then cannot touch. Three of the four
  writers here are already fine — the agent is exec'd as `1000:1000`, DDEV sets
  its web container to the host uid, and rootlesskit maps a nested container's
  root back to the dind user, which is 1000 on the host — so what remains is a
  deliberate `docker exec -u 0`. `claudebox fix-perms` is the sweep for it, run
  on demand rather than per start (a full walk of a large tree, over USB, is not
  a thing to do on every launch). It chowns from **inside** the box, where root
  is already available on the same bind, so the host user needs no `sudo`. For a
  blanket guarantee instead, `bindfs --force-user` reproduces the squash exactly
  at the cost of a FUSE layer on every stat; kernel idmapped mounts cannot —
  they shift disjoint ranges and cannot collapse many uids onto one.

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
- **`xvfb-run` hangs forever if it is PID 1 in a container.** It waits for
  `SIGUSR1` from Xvfb to know the display is ready, and a PID 1 with no
  handler installed yet never gets it — the X server is up, the socket is in
  `/tmp/.X11-unix`, and the command it was supposed to run never starts. The
  box and the runner are safe (compose gives both `init: true`, so PID 1 is
  docker-init), but a container a test starts itself is not: `docker run
  ... xvfb-run npx wdio` hangs, `docker run --init ...` does not. Beware
  `bash -c 'xvfb-run ...'` too — bash execs a lone final command, which is how
  xvfb-run ends up as PID 1 in the first place.
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

# A virtual display comes up, for suites whose browser is headful. xvfb-run
# only returns once Xvfb has signalled that it is accepting connections, so a
# zero exit here covers the server, xauth and the base fonts together.
claudebox shell -lc 'xvfb-run -a bash -c "echo ok on \$DISPLAY"'
runner exec 'xvfb-run -a bash -c "echo ok on \$DISPLAY"'

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

# Both agents are installed and start. The second line also proves the
# launcher's dispatch: "opencode" must be consumed as a subcommand, not handed
# to claude as an argument.
claudebox shell -c 'claude --version; opencode --version'
claudebox opencode --version

# opencode's box notes are wired in -- the config it resolves must carry the
# path, and the path must carry box-CLAUDE.md's content
claudebox opencode debug config | jq -e '.instructions | index("/etc/claudebox/AGENTS.md")'
claudebox shell -c 'head -1 /etc/claudebox/AGENTS.md'

# The model catalogue host is reachable. Worth checking explicitly: a denial
# here is silent, opencode just uses its built-in list.
claudebox shell -c 'curl -s -o /dev/null -w "%{http_code}\n" https://models.opencode.ai/'

# Plugins. The shipped ones are listed, and the three dispatch outcomes hold --
# the third is the one that matters: an unknown PLUGIN must reach claude
# untouched, or every prompt beginning with a colon-word has been quietly
# stolen. Point the workspace at something that does not exist so the
# fallthrough stops at the workspace check instead of starting a session.
claudebox plugins
claudebox example:hello one 'two three'
claudebox example:helo; echo "want 2, got $?"
BOX_WORKSPACE_HOST=/nonexistent claudebox nosuch:thing 2>&1 | grep -q 'workspace /nonexistent' \
    && echo ok || echo 'BAD: intercepted an argument meant for claude'
BOX_WORKSPACE_HOST=/nonexistent claudebox 'TODO: fix the parser' 2>&1 | grep -q 'workspace /nonexistent' \
    && echo ok || echo BAD
BOX_WORKSPACE_HOST=/nonexistent claudebox '..:passwd' 2>&1 | grep -q 'workspace /nonexistent' \
    && echo ok || echo 'BAD: a name became a path'

# A plugin reaches the box the same way a session does -- same container, same
# uid, and the working directory a session would have started in.
claudebox example:versions

# The agent door is off unless asked for: no container, no published port, and
# no listener in the box.
docker ps --format '{{.Names}}' | grep -q agent-relay && echo BAD || echo ok
claudebox shell -c 'ss -ltn 2>/dev/null | grep -q 7995' && echo BAD || echo ok

# "claudebox agent start" is the whole setup, and refuses on a machine that
# hosts a runner -- serving a door there is what the feature exists to prevent.
claudebox agent start
docker run -d --rm --name claudebox-runner alpine sleep 60
claudebox agent start; echo "want non-zero, got $?"
# ...but plugins do run there, which is what makes jira:triage-issue usable on
# the machine that holds its credential.
claudebox plugins >/dev/null && echo ok
claudebox jira:config >/dev/null 2>&1; echo "want 0, got $?"
claudebox shell -c true 2>/dev/null; echo "want non-zero, got $?"
docker rm -f claudebox-runner

# stop is the pair of start, and keeps the identity: the fingerprint before and
# after must match, or every joined machine has been silently un-joined.
claudebox agent status | grep fingerprint
claudebox agent stop && claudebox agent start
claudebox agent status | grep fingerprint

# ps and kill, against a session that is definitely still going. kill must take
# the tool processes with it -- a jest run outliving the session that started it
# is the failure this collects descendants to avoid -- and must refuse a pid
# that is not a session, or it is a way to signal anything in the box.
cd ~/Projects/<a project>
claudebox -p 'Use the Bash tool to run: sleep 90. Then say done.' >/dev/null 2>&1 &
sleep 10
claudebox ps                        # project, "doing: sleep 90", the prompt
claudebox kill $(docker exec claudebox pgrep -f 'agent-serve') ; echo "want 2, got $?"
claudebox kill                      # one session running, so no pid needed
docker exec claudebox sh -c "ps -eo args | grep -c '[s]leep 90'"   # want 0

# With the door up: the front door is on the LAN, the box
# is NOT, and the door refuses anything without the token. The second line is
# the one that matters -- publishing the box's own listener would be the easy
# mistake, and it would give the LAN a socket inside the sandbox.
curl -sk --max-time 5 -o /dev/null -w '%{http_code}\n' https://127.0.0.1:7996/health   # 401
curl -s  --max-time 3 http://127.0.0.1:7995/health && echo BAD || echo ok
docker exec claudebox-agent-relay node -e "require('http').get('http://claude:7995/health',r=>process.exit(r.statusCode===200?0:1))" && echo ok

# The token never reaches a command line -- it goes in on stdin. Watch a
# forwarded run: the docker run that carries it must name no secret.
ps -ww -eo args | grep '[s]end.mjs'

# On a machine hosting a runner (test with a stand-in container of that name):
# everything refuses except the two exemptions, and a headless run goes over.
docker run -d --rm --name claudebox-runner alpine sleep 600
for c in "" "shell -c true" "opencode --version" "plugins" "stop"; do
    claudebox $c >/dev/null 2>&1; echo "want non-zero, got $?"
done
claudebox agent show >/dev/null && echo ok      # exempt
claudebox help >/dev/null && echo ok            # exempt
cd ~/Projects/<a project>
claudebox -p 'print your working directory and hostname'   # answered on the OTHER machine
claudebox --project no-such-project -p x; echo "want non-zero, got $?"
docker rm -f claudebox-runner

# The jira plugin's credential must be unreachable from every container. These
# are properties of where it is written, so they hold whether or not a token is
# configured -- run them after "claudebox jira:config set".
ls -ld ~/.claudebox/plugin-state/jira ~/.claudebox/plugin-state/jira/credentials  # 0700, 0600
claudebox shell -c 'cat ~/.claudebox/plugin-state/jira/credentials' 2>&1 | grep -q 'No such file' \
    && echo ok || echo 'BAD: the box can read the token'
docker exec claudebox env | grep -qi jira && echo 'BAD: in the box environment' || echo ok
grep -qi atlassian ~/.claudebox/allowlist.conf \
    && echo 'BAD: the box has been given a route to JIRA' || echo ok

# And out of the process table, which is the part that is easy to regress: the
# credential goes to curl on stdin (-K -), never as -u. Watch a request in
# flight -- the curl line must carry no credential at all.
claudebox jira:config test & sleep 1; ps -ww -eo args | grep '[c]url -sS'; wait
```

The two images must be indistinguishable to a test. This is the one check to run
after touching the `base` stage, and the one to run on a new runner machine:

```bash
ui-parity claudebox:latest > /tmp/box && ui-parity claudebox-runner:latest > /tmp/runner
diff /tmp/box /tmp/runner
```

After a change to the `base`/`claudebox` stage split, the acceptance test is
"nothing changed" — the claudebox image must still be exactly what it was:

```bash
docker run --rm --entrypoint sh claudebox:latest -c '
  id dizzy; pwd; env | grep -E "BOX_USER|^HOME|NODE_EXTRA|PHPANTOM"
  for b in claude opencode typescript-language-server phpantom_lsp ddev runner \
           claudebox-ddev-fixups claudebox-strip-artifacts docker composer php \
           node fc-cache convert rsync socat; do
    printf "%-28s %s\n" "$b" "$(command -v $b || echo MISSING)"
  done
  ls /etc/fonts/conf.d/ | grep -E "sub-pixel|bitmaps"'
```

With a runner joined, these exercise the whole remote path. The confinement ones
matter most: every path in every request is attacker-controlled by construction.

```bash
claudebox runner test                     # reachable, token accepted, cert pinned

# Sync is idempotent, and does NOT delete the runner's own build output.
cd ~/Projects/<project>
claudebox shell -c 'runner sync && runner sync'         # second must send 0
claudebox shell -c 'runner exec "composer install -q" && runner sync \
                    && runner exec "ls vendor/autoload.php"'

# Streams output, and returns the remote exit code -- both directions.
claudebox shell -c 'runner run "vendor/bin/phpunit"; echo "exit=$?"'
claudebox shell -c 'runner exec "exit 42"; echo "exit=$?"'   # must print 42

# Confinement. Every one must be refused, and the box must have no other way
# to reach the runner machine at all.
claudebox shell -c 'node -e "
  const http=require(\"node:http\");
  const bad=[[\"/exec\",{project:\"../../etc\",command:\"id\"}],
             [\"/exec\",{project:\"/etc\",command:\"id\"}],
             [\"/exec\",{project:\"matomo\",workdir:\"../../..\",command:\"id\"}],
             [\"/exec\",{project:\".\",command:\"id\"}],
             [\"/sync/nope\",{}]];
  for (const [p,b] of bad) {
    const body=JSON.stringify(b);
    const r=http.request({host:\"runner-relay\",port:7997,path:p,method:\"POST\",
      headers:{\"content-type\":\"application/json\",\"content-length\":Buffer.byteLength(body)}},
      res=>console.log(res.statusCode===200?\"BAD \"+p:\"ok \"+p));
    r.end(body);
  }"'

# The runner refuses anything without the token, and the relay refuses a
# certificate that is not the pinned one (run on the host):
curl -sk -o /dev/null -w '%{http_code}\n' https://<runner>:7998/health   # 401

# The enrolment code is single-use, and ten wrong ones close the window rather
# than allowing unlimited guesses. On the runner: claudebox-runner enrol
claudebox runner add <runner>:7998 <code>      # joins
claudebox runner add <runner>:7998 <code>      # "enrolment is closed"
for i in $(seq 1 10); do claudebox runner add <runner>:7998 zzzzzzzz; done
claudebox-runner join                          # window gone; says how to reopen

# /enrol is the one route with no token check, so it must NOT be reachable from
# the box -- otherwise the box could re-issue itself a token it is not meant to
# hold. Must print 404, not 403.
claudebox shell -c 'node -e "
  const http=require(\"node:http\"), b=JSON.stringify({code:\"x\"});
  const r=http.request({host:\"runner-relay\",port:7997,path:\"/enrol\",method:\"POST\",
    headers:{\"content-type\":\"application/json\",\"content-length\":Buffer.byteLength(b)}},
    res=>console.log(res.statusCode));
  r.end(b)"'
```

DDEV on the runner. The first two are the ones that fail silently rather than
loudly, so check them by value and not by "the project started":

```bash
cd ~/Projects/<a ddev project>
claudebox shell -c 'runner run "ddev start -y && claudebox-ddev-bridge"'

# The project answers, and its certificate verifies against the runner's own
# mkcert root. ssl_verify_result must be 0.
claudebox shell -c 'runner exec "curl -sS -o /dev/null \
  -w \"%{http_code} %{ssl_verify_result}\n\" https://<project>.ddev.site/"'

# Every project hostname points at the sidecar, NOT at 127.0.0.1 -- 127.0.0.1
# means requests are landing on the runner container itself and the project
# looks dead for no visible reason.
claudebox shell -c 'runner exec "claudebox-ddev-bridge --status"'

# db:3306 from the runner container, which is the path a test fixture uses when
# it needs the database and Docker in the same process. Through PHP, because
# there is no mysql CLI in the image -- php-mysql is the extension.
claudebox shell -c 'runner exec "php -r \'\''\$m=new mysqli(\"db\",\"db\",\"db\",\"db\",3306);
  echo \$m->connect_errno ? \"FAIL \".\$m->connect_error.\"\\n\" : \"ok\\n\";\'\''"'

# Both fixups apply and then report ok. Idempotent, so run it twice.
claudebox shell -c 'runner exec "claudebox-ddev-fixups && claudebox-ddev-fixups --check"'

# A recreate of the runner throws /etc/hosts away; the bridge must put it back
# rather than leaving a running project unreachable by name.
claudebox-runner stop && claudebox-runner >/dev/null
claudebox shell -c 'runner exec "claudebox-ddev-bridge --status"'   # 127.0.0.1
claudebox shell -c 'runner exec "claudebox-ddev-bridge && claudebox-ddev-bridge --status"'
```

The CI-shaped addresses. **The first is the one that decides whether screenshot
baselines can ever match**, and it fails silently -- the suite runs, the visits
log fills in, and only the IP text in the image is wrong:

```bash
cd ~/Projects/matomo
claudebox shell -c 'runner exec "ddev exec \"printf %s \\\"<?php echo \\\\\$_SERVER[REMOTE_ADDR];\\\" > /var/www/html/p.php\" \
  && curl -sS http://host.docker.internal/p.php && echo \
  && curl -sS https://matomo.ddev.site/p.php && echo \
  && ddev exec rm -f /var/www/html/p.php"'
# host.docker.internal MUST print 127.0.0.1. Through the router it will not --
# that is why the front door exists, not a fault.

# The passthrough: plain http to a project must reach THAT project through the
# router, not the one the front door points at.
claudebox shell -c 'runner exec "curl -sS -o /dev/null -w \"%{http_code}\n\" http://matomo.ddev.site/"'

# The loopback forwarders exist (wp-env's ports), listening in the runner itself.
claudebox shell -c 'runner exec "ss -ltn 2>/dev/null | grep -E \"127.0.0.1:(8888|8889)\" || \
  echo MISSING -- check CLAUDEBOX_DIND_PORTS"'

# Artifacts round-trip, and refuse to leave the project.
claudebox shell -c 'runner exec "mkdir -p probe && date > probe/one.txt"'
claudebox shell -c 'runner fetch probe' && cat probe/one.txt && rm -rf probe
claudebox shell -c 'runner fetch ../elsewhere'   # must refuse
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
- **Add a launcher command** → a plugin (`cp -r plugins/example
  plugins/<name>`, see *Plugins*), not a new arm in the launcher's dispatch. It
  cannot shadow a built-in or shorten the list of arguments that reach `claude`,
  it reaches the box through `box_exec` in `plugin-api.sh` rather than through a
  second copy of the exec flags, and it is a directory of scripts rather than
  another branch in a 1400-line file. Reserve a built-in for what the launcher
  itself has to do — bringing the stack up, the allowlist, the workspace — where
  the command is inseparable from the launch path it runs before.
- **Give a plugin a credential** → a file in `${CLAUDEBOX_PLUGIN_STATE}`, `0600`
  in a `0700` directory, as `plugins/jira/lib/jira.sh` does it. Nothing mounts
  `plugin-state/`, which is the whole reason it is the right place. Do **not**
  put it in `~/.claudebox/config` alongside the launcher's settings, under
  `~/.claude` (mounted read-only at `/host/claude`), or anywhere in the
  workspace. Hand it to `curl` on stdin with `-K -` rather than `-u`, and do not
  give the command a `--token` flag: process arguments are world-readable and a
  token typed on a command line is in the shell history too. If the plugin needs
  a host the box cannot reach, that is a feature — resist adding it to
  `allowlist.conf` to "make it work", since the fetch is happening on the host.
- **Share the workspace with another machine** → `claudebox mutagen start` here
  and `claudebox mutagen attach` there, not a new bind and not a network
  filesystem (git is the workload, and git walks the whole tree). Note what it
  does *not* do: the door and the syncer are containers of their own on `edge`
  with no route to `inner`, so this is not an exception to the rule below —
  nothing was published on the `claude` service, and a machine that syncs the
  workspace still cannot reach the box, dind, the proxy or either relay. See *Sharing the workspace
  between machines*.
- **Let something else reach the box from the LAN** → through `agent-relay`, one
  named route at a time, never by publishing a port on the `claude` service. The
  box having no LAN-facing socket is what makes "the box cannot talk to the LAN"
  true in both directions; a published port would hand any host on the network a
  socket inside the sandbox. Same rule as `ddev-relay` and `runner-relay`:
  rebuild the headers, forward one route, and keep the destination fixed.
- **Add something to the plugin API** → `plugin-api.sh`. It is sourced by the
  launcher as well, so it must stay functions-only: no `set -e`, no top-level
  state, and everything it needs read from the exported `BOX_*`/`CLAUDEBOX_*`
  variables at call time. Export any new variable a plugin needs from the
  launcher, next to the other `CLAUDEBOX_*` exports, and document it in *What a
  command is*.
- **A browser fails to start with `error while loading shared libraries`** → the
  published dependency lists for headless Chromium are all incomplete in some
  direction; derive the real one instead of guessing. Run
  `ldd <chrome-binary> | grep "not found"` in the box, add the owning packages to
  the Chromium block in the `Dockerfile`, rebuild, repeat until it is empty. That
  is how `libxshmfence1` got there — it is absent from every list upstream
  publishes. `ldd` cannot see libraries opened with `dlopen` at runtime, so
  finish by actually launching the browser.
- **Add something the tests need (a font, a PHP extension, a library)** → the
  `base` stage of `Dockerfile`, not the `claudebox` stage and not
  `runner/Dockerfile`. Both images come off `base`, which is what keeps
  screenshot baselines comparable between the box and the runner; anything added
  below that boundary is by construction invisible to a test. `runner/Dockerfile`
  is for the runner's *role* — ddev, mkcert, its one sudo rule — never for the
  environment a test runs in.
- **Change what the box's agent knows about its environment** → `box-CLAUDE.md`,
  then `claudebox rebuild`. It lands at `/etc/claude-code/CLAUDE.md`, Claude
  Code's managed-policy memory path (loaded in every session in every directory,
  not excludable by settings), and at `/etc/claudebox/AGENTS.md`, which opencode
  picks up through the baked config. Keep it about the box, not about either
  agent, since both read it. Don't move it to `~/.claude/CLAUDE.md` — HOME is a
  volume `entrypoint.sh` seeds once, so edits there would never land — or to
  `~/Projects/CLAUDE.md`, which the host's own sessions would then load. Keep it
  short; it costs context in every session.
- **Add another agent** → install it in the `Dockerfile`, add a subcommand next
  to `opencode` in the launcher, and give it `box-CLAUDE.md` by whatever
  mechanism it has for always-on instructions (a baked path it is configured to
  read, never a copy in HOME). Seed its host config the way the opencode binds
  do it — conditional, read-only, copied once. Then check `claudebox denied`
  after the first real session: the hosts an agent needs are rarely all
  documented, and a blocked one usually degrades quietly rather than erroring.
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
