# syntax=docker/dockerfile:1
#
# The claudebox runner relay. Holds the remote runner's address, token and
# pinned certificate fingerprint, and exposes five forwarded routes to the box
# over the internal network -- and nothing else. See relay.mjs for the trust
# model; it is the same one ddev-relay uses for the host Docker socket.

FROM node:22-alpine

COPY relay.mjs /app/relay.mjs

# Fail fast and loudly rather than restarting into a broken state.
ENV NODE_OPTIONS=--unhandled-rejections=strict

EXPOSE 7997
CMD ["node", "/app/relay.mjs"]
