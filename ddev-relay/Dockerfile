# syntax=docker/dockerfile:1
#
# The claudebox ddev-exec relay. Holds the host Docker socket and exposes a
# single constrained operation to the box over the internal network: run a
# command in a DDEV project's service container (`ddev exec`), and nothing else.
# See relay.mjs for the trust model.

FROM node:22-alpine

# docker CLI only -- the relay drives the mounted HOST socket with it.
RUN apk add --no-cache docker-cli

COPY relay.mjs /app/relay.mjs

# Fail fast and loudly rather than restarting into a broken state.
ENV NODE_OPTIONS=--unhandled-rejections=strict

EXPOSE 7999
CMD ["node", "/app/relay.mjs"]
