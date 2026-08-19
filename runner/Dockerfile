# syntax=docker/dockerfile:1
#
# claudebox-runner: the box's environment minus the agent, plus a network API.
#
# FROM the base stage of the repo's main Dockerfile, and that is the entire
# point of this image. Matomo's UI baselines are sensitive to font PACKAGE
# VERSIONS -- fonts-dejavu-core 2.37-6 against 2.37-8 renders every glyph a
# pixel off -- so an environment assembled independently on the runner machine
# would produce screenshot diffs that look exactly like real regressions. Coming
# off the same layers as the box makes that parity structural instead of a thing
# to keep in step by hand.
#
# The base image is not published anywhere; the claudebox-runner launcher builds
# it from the checkout on this machine first, which is why it is an ARG rather
# than a hard-coded tag.
ARG BASE_IMAGE=claudebox-base:latest
FROM ${BASE_IMAGE}

# Nothing is installed here. Everything the service needs -- node, tar, openssl,
# git, the docker CLI it drives its own dind with -- is already in base, because
# the tests need all of it too. An apt-get in this file would be a divergence
# from the box's environment by definition, so if something is missing it
# belongs in base.

COPY runner.mjs /app/runner.mjs
COPY entrypoint.sh /usr/local/bin/runner-entrypoint.sh
RUN chmod 0755 /usr/local/bin/runner-entrypoint.sh

# Fail fast and loudly rather than restarting into a broken state.
ENV NODE_OPTIONS=--unhandled-rejections=strict

EXPOSE 7998
ENTRYPOINT ["/usr/local/bin/runner-entrypoint.sh"]
CMD ["node", "/app/runner.mjs"]
