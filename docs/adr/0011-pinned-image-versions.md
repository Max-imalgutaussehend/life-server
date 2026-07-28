# ADR-0011: Pinned image versions, never `latest`

- **Status:** Accepted
- **Date:** 2026-07-28
- **Milestone:** M0

## Context

`image: postgres` or `image: postgres:latest` means the version deployed depends
on when `docker compose pull` last ran. A service untouched for months can break
on an unrelated restart, and the running system cannot be reconstructed from the
repository — which contradicts the entire point of this setup.

For PostgreSQL specifically, a major version jump on restart will refuse to
start against an existing data directory. That is a production outage triggered
by an unrelated action.

## Decision

**Every image is pinned to an explicit minor version.**

```yaml
image: postgres:17.6      # not postgres, not postgres:17, not latest
image: redis:8.2
image: caddy:2.10
image: n8nio/n8n:1.109.2
```

Updates are deliberate: bump the tag, commit, deploy, verify. Renovate opens
pull requests for available updates; it never applies them.

## Alternatives considered

**Digest pinning (`postgres@sha256:...`).** Byte-exact reproducibility, immune
to tag mutation. Rejected as the default: unreadable in diffs and in the Compose
file. Reconsider for the deploy pipeline in M7, where images are built and
addressed by SHA anyway.

**Major-version tags (`postgres:17`).** Automatic patches, no major surprises.
Rejected: still not reproducible — `postgres:17` today and in six months are
different images, and a patch release can still change behaviour.

**`latest` with pinned Renovate updates.** Rejected: `latest` is exactly the
mutable reference this ADR exists to eliminate.

## Trade-offs

**Gained:** `git checkout` of an old commit describes exactly what ran.
Upgrades are events with a diff and a rollback, not accidents.

**Given up:** security patches require action. An unattended pinned image can
sit on a known-vulnerable version — this is the real cost, and it is why
Renovate is mandatory rather than optional.

## Consequences

- Renovate is configured in M7 (it needs the repo on GitHub) to raise PRs for
  image updates. Chosen over Dependabot because it understands Docker tags
  inside Compose files.
- Major upgrades — especially PostgreSQL — need a documented procedure: backup,
  dump, upgrade, restore, verify.
- A pre-commit hook rejects `:latest` in any Compose file.

## Follow-up

- [ ] M2: pre-commit rule rejecting `:latest`
- [ ] M4: document the PostgreSQL major upgrade procedure
- [ ] M7: Renovate configuration
