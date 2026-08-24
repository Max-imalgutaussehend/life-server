# =============================================================================
# Dockerfile — OmniRoute, the fallback model router. (M13, ADR-0021)
# =============================================================================
#
# WHY THIS IS BUILT AND NOT PULLED
#   Upstream advertises `docker run omniroute` but publishes no image under a
#   namespace that can be pinned by digest — the documented install is
#   `npm i -g omniroute`. Building here is the same trade already made for
#   Hermes: an npm install is small enough to build on this host, and it pins a
#   VERSION instead of trusting a floating tag (ADR-0011).
#
# WHY node:22-alpine
#   OmniRoute is Node with SQLite. Unlike hermes-agent it pulls no C-extension
#   wheels that musl would fail to resolve — better-sqlite3 publishes prebuilt
#   musl binaries — so Alpine's smaller footprint is safe to take here.
#   That matters: this container exists to add resilience, not to eat the
#   memory budget the agents need.
# =============================================================================

FROM node:22-alpine

# Pinned deliberately. An unpinned router would change the routing behaviour of
# every agent turn on a rebuild, silently.
#
# ⚠️ VERIFY BEFORE FIRST DEPLOY: this version was NOT confirmed against the
# registry — the build host had no route to npm at authoring time (the
# operator's uplink was IPv6-only and the server is v4). `npm view omniroute
# versions` on the server settles it; if this tag does not exist the build
# fails loudly here rather than silently installing `latest`.
ARG OMNIROUTE_VERSION=1.0.0

# python3/make/g++ are present only in case no prebuilt SQLite binary exists
# for this platform; removed again in the same layer so they never reach the
# runtime image. tini as PID 1 for the same reason as Hermes: the router spawns
# per-request children and without an init they accumulate as zombies.
RUN apk add --no-cache tini \
	&& apk add --no-cache --virtual .build-deps python3 make g++ \
	&& npm install -g "omniroute@${OMNIROUTE_VERSION}" \
	&& apk del .build-deps \
	&& npm cache clean --force

# Non-root. This sits in the `agent` network alongside containers that execute
# model-chosen code, so the M9 sandbox rule applies: uid 65534 owns nothing
# worth taking.
RUN mkdir -p /data && chown 65534:65534 /data
USER 65534:65534
WORKDIR /data

# HOME must be writable: OmniRoute keeps its SQLite database, provider registry
# and AES-encrypted credentials under the user's home. Pointing it at the
# mounted volume is what makes provider config survive a recreate.
ENV HOME=/data \
	NODE_ENV=production \
	OMNIROUTE_PORT=20128

EXPOSE 20128

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["omniroute"]
