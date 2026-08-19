# syntax=docker/dockerfile:1
#
# The claudebox agent front door. Holds THIS machine's identity -- a token and a
# self-signed certificate -- and forwards one route into the box over the
# internal network. See relay.mjs for the trust model and how it mirrors
# runner-relay, which is the same shape pointed the other way.

FROM node:22-alpine

# openssl for the token and the certificate, generated on first start into the
# state volume. Alpine's node image has libssl but not the command.
RUN apk add --no-cache openssl

COPY relay.mjs /app/relay.mjs
COPY entrypoint.sh /usr/local/bin/agent-entrypoint.sh
COPY open-enrolment.sh /usr/local/bin/claudebox-agent-enrol

# The join-time half, run as a one-off container on the RUNNER machine rather
# than by this service -- the same arrangement runner-relay uses, and for the
# same reason: it is the image that has node and a route to the other machine.
COPY enrol.mjs /app/enrol.mjs

# And the send half, run the same way: the launcher on the runner machine pipes
# a request in on stdin and this streams the run's output back out.
COPY send.mjs /app/send.mjs

RUN chmod 0755 /usr/local/bin/agent-entrypoint.sh /usr/local/bin/claudebox-agent-enrol

# Fail fast and loudly rather than restarting into a broken state.
ENV NODE_OPTIONS=--unhandled-rejections=strict

EXPOSE 7996

# The entrypoint script is part of the DEFAULT COMMAND rather than an ENTRYPOINT,
# and that is load-bearing: this image is also run as a one-off container for the
# join and send clients --
#
#   docker run --rm -i claudebox-agent-relay:latest node /app/send.mjs
#
# -- and an ENTRYPOINT would run ahead of those too, generating a throwaway token
# and certificate in a container with no state volume and opening an enrolment
# window that exists nowhere. Overriding the command, as those calls do, has to
# mean the identity work is skipped.
CMD ["/usr/local/bin/agent-entrypoint.sh", "node", "/app/relay.mjs"]
