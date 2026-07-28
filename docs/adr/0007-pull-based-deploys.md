# ADR-0007: Pull-based deployment; CI never holds SSH access

- **Status:** Accepted
- **Date:** 2026-07-28
- **Milestone:** M0 (decision), M7 (implementation)

## Context

"GitHub Actions deployments" was a stated requirement. The default
implementation puts an SSH private key in GitHub Secrets and has the runner
`ssh` into the server to run `docker compose up`.

That means a credential with shell access to a hardened server lives on
infrastructure you do not control, usable by anyone who can trigger a workflow
or compromise the repository.

## Decision

**GitHub Actions builds and pushes images to GHCR. The server pulls.**

```
push to main
   -> Actions builds image
   -> pushes to ghcr.io/<user>/<service>:<sha>
   -> server (timer or webhook) pulls and restarts
```

GitHub holds only a GHCR token scoped to package write. It has no route into
the server, and the server accepts no inbound connection from CI.

**Documented fallback**, if a simpler start is wanted: an SSH key restricted in
`authorized_keys` with `command="/opt/life-server/scripts/deploy.sh",no-pty,
no-port-forwarding,no-agent-forwarding`. That key can invoke exactly one script
and nothing else. Materially weaker than pull-based, but far better than shell
access.

## Alternatives considered

**SSH key with full shell access in GitHub Secrets.** Universally used, simple.
Rejected: gives a third party root-equivalent access to the server.

**Self-hosted GitHub runner on the server.** No inbound access needed. Rejected:
the runner executes arbitrary workflow code on the host with whatever privileges
it has — strictly worse than a scoped pull, and a known attack path for public
repositories.

**Watchtower (auto-pull on image change).** Zero deploy code. Rejected: pulls
whatever is tagged latest, which conflicts with pinned versions (ADR-0011) and
removes the human decision point from production changes.

## Trade-offs

**Gained:** CI compromise cannot become server compromise. Works unchanged when
SSH is closed to the internet (ADR-0013), because deploys need no inbound path.

**Given up:** deploys are not instantaneous — a poll interval, or a webhook via
the tunnel, is required. More moving parts than `ssh && docker compose up`.

**Note:** with SSH closed in M8.5, push-based deploys would need Tailscale on
the CI runner. Pull-based sidesteps this entirely, which is a second reason to
prefer it.

## Consequences

- Images must be built and tagged by digest or SHA, never `latest` (ADR-0011).
- The server needs a GHCR read token in `.env` for private packages.
- A rollback is pulling the previous SHA — so old images must not be pruned
  aggressively.

## Follow-up

- [ ] M7: GHCR authentication on the server
- [ ] M7: pull-and-restart mechanism (systemd timer, or webhook via tunnel)
- [ ] M7: document the rollback procedure with a concrete command
