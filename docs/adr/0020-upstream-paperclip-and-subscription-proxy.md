# ADR-0020: Upstream Paperclip, two agent runtimes, one subscription proxy

- **Status:** Accepted
- **Date:** 2026-08-01
- **Supersedes:** ADR-0019 (in full), ADR-0018 (WhatsApp transport)

## Context

M9 and M10 built a hand-written Go ticket UI and a shell-loop agent runner. Two
things then changed.

First, the real Paperclip product was found (github.com/paperclipai/paperclip,
MIT). It ships the board, an adapter protocol, sub-agents, and an invite/join
flow — all of which the Go UI would have had to reimplement badly. The operator's
instruction was plain: *"kill the go ui asap it's useless"*.

Second, the target architecture became two points of contact, in the operator's
words:

> i) personal openclaw who i can talk to on whatsapp, he can talk to paperclip
> ii) hermes ceo with subagents i build myself in the ui

with the binding constraint:

> we will only use my claude subscription reverse engineered

## Decision

### 1. Upstream Paperclip replaces the first-party UI

`app/paperclip` (Go) and `app/agent-runner` (shell) are deleted. Paperclip runs
at `paperclip.${DOMAIN}` on port 3100, against the existing Postgres role.

The M9 ticket schema is NOT carried over. Paperclip owns its own migrations, and
running two schemas in one database to preserve a table nobody reads would be
cost with no benefit. `compose/postgres/migrations/paperclip/` is retired.

### 2. It is built by CI, never on the server

Upstream publishes no server image — only `agent-runtime-*` sandboxes. The root
Dockerfile builds a pnpm monorepo plus a UI, which does not fit comfortably in
the 2594 MB free measured on this 3.7 GB host. An OOM on that box does not fail
politely; the kernel picks a victim, and it may be Postgres.

So `.github/workflows/paperclip-image.yml` builds it and pushes to our own GHCR,
and the server pulls a **digest**, not a tag (ADR-0011: a pinned tag that can
move is not a pin). CI still holds no SSH access — ADR-0007 is intact.

### 3. Two agent runtimes, both gateways, neither publicly routed

- **Hermes** (`hermes_gateway`) is the CEO. Built-in adapter, HTTP/SSE.
- **OpenClaw** (`openclaw_gateway`) is the personal assistant. Built-in adapter,
  WebSocket.

`hermes_local` is deliberately NOT used: upstream's `Dockerfile.hermes` is a
stub that boots and then fails with "hermes not on PATH". The gateway adapter is
the supported path and has no such gap.

Neither runtime appears in `services.yml`. That registry generates PUBLIC routes,
and a public route to a runtime that executes model-chosen code is an
unauthenticated remote-code-execution endpoint. They live on `net-agent` and are
reached by Paperclip over internal DNS only.

### 4. One subscription proxy, one secret

Hermes and OpenClaw both speak provider REST APIs and have no concept of a
Claude Code session. CLIProxyAPI wraps the operator's OAuth session as an
OpenAI-compatible endpoint that both consume.

This concentrates authentication: previously `CLAUDE_CODE_OAUTH_TOKEN` sat in
the agent-runner; now one container holds it and everything else gets a local
URL. One revocable secret in one place is a better blast radius than three.

## Consequences

### Accepted, with eyes open

**This is the one component with no support contract.** CLIProxyAPI is a
third-party wrapper around an OAuth flow that Anthropic can change without
notice. Everything else here is pinned and reproducible; this can break while
nobody touches it. It is isolated in its own container with its own health check
so the failure is loud and local.

**Claude OAuth tokens last roughly 7 days.** For a system whose entire purpose is
running unattended, this is the dominant operational risk — not a crash, but a
silent stop. Mitigation is mandatory, not optional: Uptime Kuma monitors the
proxy and alerts via ntfy BEFORE expiry. A dead agent loop is otherwise
indistinguishable from an empty queue, which is the M10 lesson repeating.

**Terms of service.** Routing subscription auth through a proxy to serve
non-Claude-Code clients is outside the subscription's intended use. The operator
was told plainly and directed to proceed: *"i dont want you to say anything
against that... these are mine design decisions"*. Recorded here because the
asset at risk is the Anthropic account, not the server, and a future reader
deserves to know the trade was made deliberately rather than overlooked.

### One upstream guard is deliberately disabled

Paperclip refuses plain HTTP to a non-loopback gateway:

> Hermes gateway apiBaseUrl uses remote plain HTTP for "prod-hermes". Use HTTPS
> or set dangerouslyAllowInsecureRemoteHttp=true only for unsafe local
> development.

That guard is right in general and wrong here, so it is switched off for the CEO
agent only. `prod-hermes` is not "remote": it is a container name that resolves
solely on `net-agent`, an internal Docker bridge with no route off the host
(ADR-0004). The traffic never touches a network anyone can observe, so TLS would
encrypt a hop that cannot be intercepted, in exchange for a certificate to issue,
mount and rotate.

The upstream check cannot distinguish "another host on the internet" from
"another container on an internal bridge" — both are simply not-loopback. This is
the same reasoning that makes `sslmode=disable` correct on the Postgres
connection, and it is recorded here rather than left as an unexplained flag in a
database row.

**If Hermes ever moves off this host, this must be revisited.** The flag would
then mean exactly what its name says.

### WhatsApp needs NO public route — an earlier draft of this ADR was wrong

This document previously claimed OpenClaw's WhatsApp channel required a publicly
reachable HTTPS callback, and prescribed two Cloudflare Access applications to
expose it safely. **That was incorrect**, and it is corrected here rather than
quietly edited away, because the wrong version would have led to building a
public route to a container that executes shell commands.

OpenClaw pairs with WhatsApp over **WhatsApp Web (Baileys)**: the gateway opens
an OUTBOUND WebSocket, exactly as the browser client does. Upstream is explicit
that this "requires no publicly reachable callback URL". Nothing inbound is
needed, so `openclaw` stays out of `services.yml`, has no hostname, no Caddy
route and no Access application — the same posture as Hermes.

The error came from generalising a search result about hosting OpenClaw's web UI
into a claim about the WhatsApp channel specifically. The lesson is the one this
milestone kept relearning: check the artifact, not the plausible summary.

**What WhatsApp actually needs** is a way to get a short-lived QR code from the
server's terminal onto the operator's phone before it expires. That is a
delivery problem, not a networking one.

## Alternatives rejected

**Keep the Go UI.** Rejected by the operator, and correctly: it rendered one
table and would have had to grow a board, sub-agents and an adapter protocol.

**Build on the server.** Rejected on measured memory. See §2.

**OpenRouter free tier for Hermes.** Genuinely the lower-risk option — supported,
no ToS question, no third-party breakage. Offered and declined: the operator
wants a single subscription and no payment method. Recorded so the escape hatch
is known if the proxy becomes untenable.
