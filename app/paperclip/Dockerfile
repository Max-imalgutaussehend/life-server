# =============================================================================
# Paperclip — the ticket UI. The repository's first first-party image. (M9)
# =============================================================================
#
# MULTI-STAGE SO THE SERVER NEEDS NO TOOLCHAIN
#   The build stage has the Go compiler; the final stage has a single static
#   binary and nothing else. Installing Go on the host would be a permanent
#   dependency to patch in exchange for a one-off compile.
#
# PINNED, like every other image here (ADR-0011). A moving base tag means a
# rebuild months from now silently produces a different artifact.
# =============================================================================

FROM golang:1.25.1-alpine AS build

WORKDIR /src

# Dependencies first, in their own layer: they change far less often than the
# code, so an edit to main.go does not re-download the module cache.
COPY go.mod go.sum ./
RUN go mod download

COPY main.go ./
COPY templates ./templates

# CGO_ENABLED=0 produces a genuinely static binary, which is what lets the
# final stage be scratch rather than alpine — no libc, no shell, no package
# manager, so nothing to exploit and nothing to patch.
#
# -trimpath strips local filesystem paths; -s -w drop the symbol table and DWARF
# data, roughly halving the binary.
RUN CGO_ENABLED=0 GOOS=linux go build \
	-trimpath -ldflags="-s -w" \
	-o /paperclip .

# =============================================================================

FROM scratch

# The passwd file, so the binary can run as a named non-root user rather than a
# bare uid. CA certificates are deliberately absent: the only outbound
# connection is to Postgres on the internal network, and an image that cannot
# verify a public TLS certificate cannot quietly start calling the internet.
COPY --from=build /etc/passwd /etc/passwd

COPY --from=build /paperclip /paperclip

# 65534 = nobody. A scratch image has little to attack, but running as uid 0
# anyway would be a gift to anyone who finds a bug in the binary.
USER 65534:65534

EXPOSE 8080

# No shell in a scratch image, so this is the exec form by necessity — which is
# also the correct form: signals reach the process directly, so the graceful
# shutdown in main.go actually runs.
ENTRYPOINT ["/paperclip"]
