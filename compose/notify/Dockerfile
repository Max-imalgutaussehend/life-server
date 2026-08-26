# =============================================================================
# Dockerfile — the notify courier. (M16, ADR-0024)
# =============================================================================
#
# WHY BUILT AND NOT PULLED
#   The courier needs two things in one image: the Docker CLI (to reach
#   OpenClaw through the mounted socket) and Python (to run the ~100-line
#   server). No published image has both — docker:29-cli ships no interpreter,
#   verified by running it rather than assumed.
#
#   Starting from the Docker image and adding Python is the smaller half:
#   python3 is one apk package, whereas installing the Docker CLI into a
#   Python image means adding a repository and a signing key.
# =============================================================================

FROM docker:29-cli

# python3 only — no pip, no venv. The script imports nothing outside the
# standard library, deliberately: a courier that holds the Docker socket
# should have the smallest possible dependency surface.
RUN apk add --no-cache python3

# Non-root would be the obvious next step and is NOT taken here, on purpose:
# the socket is root:docker on the host and the container needs the docker
# group to read it. `group_add` in compose supplies that GID; adding a
# non-root user as well would be a second thing to keep in sync for no real
# gain, since anything that can use this socket is root-equivalent regardless
# (ADR-0023).
#
# The mitigation is not the user id. It is that this image contains one
# script, that script never execs anything the caller chose, and the whole
# service does exactly one thing.

WORKDIR /app
EXPOSE 8099
