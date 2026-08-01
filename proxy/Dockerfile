# syntax=docker/dockerfile:1
#
# The box's only route to the internet: a Squid forward proxy that allows a
# fixed list of domains and denies everything else.

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        squid \
    && rm -rf /var/lib/apt/lists/*

COPY squid.conf /etc/squid/squid.conf
COPY allowlist.sh /usr/local/bin/allowlist

# Seed the generated ACL files with values that match nothing, so the image is
# deny-all before the first build ever runs and squid can always start.
RUN chmod +x /usr/local/bin/allowlist \
    && printf 'never.matches.invalid\n' > /etc/squid/allowlist.domains \
    && printf '^$\n' > /etc/squid/allowlist.regex

EXPOSE 3128

# The allowlist is bind-mounted, so it can have changed while the container was
# down: expand it on every start, before squid reads the ACL files.
#
# The pid file is removed first because nothing mounts over /run: it lives in
# the writable layer and outlives the process that wrote it. A squid killed
# rather than stopped (a daemon restart, "docker kill") leaves it behind, and on
# the next start squid gets the same PID it had before -- the wrapper below is
# always pid 7 in a fresh namespace and execs squid into it -- so its "already
# running?" check, which is just kill(pid, 0), succeeds against itself and it
# aborts with "Squid is already running". A container that is starting cannot
# have a live squid in it, so the file can only ever be stale here.
#
# -N runs squid in the foreground; -d1 sends the cache log to stderr so both
# show up in "docker logs".
CMD ["bash", "-c", "rm -f /var/run/squid.pid; allowlist build; exec squid -N -d1 -f /etc/squid/squid.conf"]
