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
# -N runs squid in the foreground; -d1 sends the cache log to stderr so both
# show up in "docker logs".
CMD ["bash", "-c", "allowlist build; exec squid -N -d1 -f /etc/squid/squid.conf"]
