# ADR-0023: OpenClaw gets the Docker socket

- **Status:** Accepted
- **Date:** 2026-08-26
- **Milestone:** M15
- **Overrides for one container:** ADR-0004 (segmented networks), M9 (agent sandbox)

## Context

The operator asked for an assistant that can do real work on this host:

> "ich will openclaw einfach zugang geben mit dem paperclip ceo zu reden [...]
> er soll n8n workflows bauen können und generell theoretisch auch sachen und
> weitere apps einfach bauen können auf dem server, er BRAUCHT zugriff"

Three capabilities, and the third decides the other two. "Build and deploy
apps on the server" is not a permission that can be granted in part: it means
talking to the Docker daemon.

The risk was stated before implementation and the operator confirmed it:

> "das ganze ist sicher genug, es erlaubt per cloudflare gate nur meine email,
> das genügt, wir können ihm den docker socket übergeben wenn das alles
> ermöglicht"

## Decision

**Mount `/var/run/docker.sock` into the OpenClaw container and add the Docker
CLI to its image.**

This grants the container root-equivalent access to the host. Not "broad
access" — root. The Docker API allows creating a container with `/` bind
mounted, which is the standard privilege-escalation path and requires no
exploit.

Consequences that follow automatically and are **not** mitigated:

- It can read `.env`, including every database password, the Cloudflare tunnel
  token, and the restic backup key.
- It can reach `prod-postgres` and `prod-redis` despite `net-data` being
  `internal: true`, by starting a container attached to that network.
- It can stop, modify or delete any container on this host, including itself
  and the backup job.

`security_opt: no-new-privileges` is kept on the container, and it is worth
saying plainly that it no longer means much here: escalation happens through
the daemon, not through setuid inside the container.

### What is still scoped

Two things are deliberately not merged into the blast radius:

1. **A separate workspace volume** (`openclaw_workspace:/workspace`) rather
   than a bind mount into the repository. What the agent builds lives beside
   the deployment source of truth, not inside it — a mistake there cannot
   silently rewrite the stack definition that ADR-0014 exists to protect.

2. **The network stays `agent`.** This changes nothing about what the
   container *can* reach (it can attach a new container to any network), but
   it keeps the default path honest: routine traffic still goes through Caddy,
   and `docker network inspect` still describes reality for every other
   service.

## The operator's stated mitigation, and its actual scope

The decision was made on the basis that Cloudflare Access limits entry to one
email address. That is true of `openclaw.maxrommel.de`, and it is a real
control for the web UI.

It does **not** cover the way this agent is actually used:

- **WhatsApp is the primary entry point**, over an outbound WebSocket that
  Cloudflare never sees. The allowlist there is a phone number
  (`channels.whatsapp.allowFrom`), which is an identifier, not an
  authentication factor.
- **Access filters people, not content.** Once the agent reads a web page, an
  n8n payload or a repository, text inside that content can carry
  instructions. With a shell and the Docker socket, a successful prompt
  injection is a host compromise. No login gate addresses this.

This is recorded not to relitigate the decision — it is made — but so that the
next person to read this file knows which threat the control covers and which
it does not.

## Alternatives considered

**A scoped build surface instead of the raw socket** — a small API the agent
calls to deploy from `/workspace`, with the socket held by a separate minimal
service. Gives "build and deploy apps" without giving "read every password on
the host". Rejected: the operator was shown this as stage 3 of a four-stage
proposal and chose the full socket.

**Docker socket proxy** (e.g. tecnativa/docker-socket-proxy) filtering the API
to container-create plus image-build. Meaningfully narrower — but a client that
can create containers can still mount `/`, so it narrows the interface without
narrowing the outcome. Honest only if `POST /containers/create` is also
restricted, at which point it is the scoped build surface above.

**Rootless Docker or Podman for the agent's containers.** The genuinely better
answer, and the one to revisit: the agent gets a daemon of its own that does
not run as host root. Rejected for now as a larger change than this milestone
allows, and noted as follow-up.

## Trade-offs

**Gained:** the assistant can build, deploy, inspect and repair services on
this host without a human in the loop. That is what was asked for, and it is
genuinely useful.

**Given up:** the security property this system was designed around. M9's
sandbox and ADR-0004's segmentation still hold for every other container, and
no longer hold for this one. `docs/generated/SERVICES.md` describes network
reachability that this container is exempt from.

**Given up, second order:** the ability to reconstruct what happened. An agent
with host root that misbehaves can also remove the evidence — including its own
logs and the backup that would have restored the state.

## Consequences

- `compose/openclaw/Dockerfile` builds the upstream image plus `docker-ce-cli`
  and `docker-compose-plugin`. The socket without a client is inert, which is
  why that file exists at all.
- `group_add: ["988"]` — the host's `docker` group, read from `getent`, not
  assumed. Without it the socket is present but unreadable to uid 1000.
- Any statement elsewhere in this repo that agent containers cannot reach the
  database is, from this milestone, false for `prod-openclaw` specifically.

## Follow-up

- [ ] M15: rotate every secret in `.env` if the agent is ever suspected of
      misbehaving — it can read all of them, so an incident means all of them.
- [ ] Verify backups run to a destination the agent cannot delete. Restic to
      the same host is not that; an append-only remote is.
- [ ] Revisit rootless Docker / Podman for the agent, which would give the same
      capability without host root.
- [ ] Decide whether WhatsApp should remain an entry point at this privilege
      level, or whether the web UI (behind Access) should be the only one.
