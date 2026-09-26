# syntax=docker/dockerfile:1

# =============================================================================
# end-to-end-services — Hugo static site, packaged for the shared Docker host.
#
# Stage 1 builds the site with Hugo into /src/public.
# Stage 2 serves those static files from nginx as a non-root user.
#
# No secrets, no tokens, no proxy/CA hacks live in this file. The only build
# input is HUGO_BASEURL, a public value with a safe default (the site's own
# config.toml baseURL is used when it is left empty).
# =============================================================================

# ---- Stage 1: build the static site --------------------------------------
# hugomods/hugo:0.121.2 ships Hugo Extended. This site is a 2021-era Hugo
# project, so the version is pinned: the build is clean (no WARN lines) on
# it. Bump it deliberately and read the build log when you do.
FROM hugomods/hugo:0.121.2 AS build

# baseURL is a build-time public value, not a secret. Set it for the target
# domain with (onebox passes https://<E2E_HOST>/):
#   --build-arg HUGO_BASEURL=https://your.domain/
# Hugo reads every HUGO_* environment variable as config, and a build arg is
# in the environment of the RUN below, so an empty HUGO_BASEURL would set
# baseURL to "" and make og:url, the sitemap and RSS relative. The RUN unsets
# it when empty, and config.toml's baseURL is used as-is.
ARG HUGO_BASEURL=""

WORKDIR /src

# Copy the whole source tree (the .dockerignore keeps caches and junk out).
COPY . .

# Production build: minified output, garbage-collected resources, no drafts.
# When HUGO_BASEURL is set it overrides the absolute URLs baked into the HTML.
RUN [ -n "$HUGO_BASEURL" ] || unset HUGO_BASEURL; \
    hugo --minify --gc --destination /src/public \
    ${HUGO_BASEURL:+--baseURL "$HUGO_BASEURL"}

# ---- Stage 2: serve the built site ---------------------------------------
# Pinned to a concrete minor tag (not the floating `nginx:alpine`) so a rebuild
# is reproducible and there is a supply-chain floor: the same nginx/alpine, the
# same uid-101 `nginx` user, the same /tmp temp-path assumptions this image's
# nginx.conf relies on. Bump this deliberately, the way the Hugo stage above is
# pinned. To harden further, append a digest: `nginx:1.27-alpine@sha256:<digest>`.
FROM nginx:1.27-alpine AS runtime

# curl is only here so the HEALTHCHECK can probe the site over HTTP.
RUN apk add --no-cache curl

# Non-root nginx config: listens on 8080, writes its pid and temp files under
# /tmp, and logs to stdout/stderr.
COPY nginx.conf /etc/nginx/nginx.conf

# The generated static site.
COPY --from=build /src/public /usr/share/nginx/html

# nginx:alpine already ships an unprivileged `nginx` user (uid/gid 101). Give
# it ownership of the content it serves and run as it.
RUN chown -R nginx:nginx /usr/share/nginx/html

USER nginx

# The container listens on 8080. On the shared host it sits BEHIND Caddy and
# publishes no port at all: onebox (x402-facilitator/onebox/apps/e2e.yml)
# joins it to the `edge` network as `e2e`, and Caddy's reverse_proxy target is
# e2e:8080. Every request goes through Caddy (TLS, headers, limits). To look
# at the image on its own machine, loopback only:
#   docker run --rm -p 127.0.0.1:8080:8080 end-to-end-services:onebox
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -fsS http://localhost:8080/ >/dev/null || exit 1

CMD ["nginx", "-g", "daemon off;"]
