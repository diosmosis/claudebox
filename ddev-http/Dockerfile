# syntax=docker/dockerfile:1
#
# The "host.docker.internal" front door for containers nested inside dind.
# See ddev-http/default.conf.template and the ddev-http service in
# docker-compose.yaml.

FROM nginx:alpine

# The stock entrypoint renders /etc/nginx/templates/*.template with envsubst at
# start-up. Baked in rather than bind-mounted: a bind-mounted single file can go
# stale in the container (see CLAUDEBOX.md), and this one decides where every
# request goes.
COPY default.conf.template /etc/nginx/templates/default.conf.template

# Restrict envsubst to our own variable. Without a filter it would also try to
# expand nginx's own $-variables that happen to match an environment name.
ENV NGINX_ENVSUBST_FILTER="DDEV_HOST|DDEV_WEB"
