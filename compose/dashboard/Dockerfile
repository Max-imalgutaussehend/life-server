# =============================================================================
# Dockerfile — the dashboard. (M17)
# =============================================================================
#
# WHY BUILT AND NOT PULLED
#   The page needs Python (to render) and psql (to read Paperclip). No
#   published image has both: postgres:17.7-alpine ships psql but no
#   interpreter — verified by running it, not assumed.
#
#   Starting from Postgres and adding Python is the smaller half. The reverse
#   would mean adding a Postgres apt repository and signing key to a Python
#   image, for one binary.
# =============================================================================

FROM postgres:17.7-alpine

# python3 only — no pip. The script imports nothing outside the standard
# library, so there is nothing to install and nothing to keep patched.
RUN apk add --no-cache python3

# The Postgres entrypoint would try to initialise a database cluster. This
# image is here for its client, so that is replaced wholesale in compose.
WORKDIR /app
EXPOSE 8090
