# ADR-0009: Backups ship at M5, before any service stores real data

- **Status:** Accepted
- **Date:** 2026-07-28
- **Milestone:** M0 (decision), M5 (implementation)

## Context

Backups were originally listed as a "future" item. Deferred backups do not get
built: there is always a more interesting service to add, and the cost of the
gap is invisible until the moment it is catastrophic.

A counter-argument was raised and partly accepted: do not spend a week on
backup infrastructure before anything useful runs.

## Decision

**M5 delivers working, scheduled, monitored backups — before M6 deploys n8n.**

M5 is scoped at roughly 60 minutes:

- restic container, repository on Hetzner Storage Box (or S3-compatible)
- scheduled via systemd timer
- healthcheck ping on success, alert on failure
- `make backup` and `make restore`

**Hard gate:** after M5, no service that stores data ships until its data is
in the backup set.

**The restore rehearsal is mandatory and happens in M5**, using a throwaway
database rather than waiting for real data. The objection "there is nothing to
restore yet" misreads what is being tested: the rehearsal validates
credentials, network path, encryption and the restore command — not the data.
Discovering that `RESTIC_PASSWORD` was stored wrong is cheap against a
throwaway database and expensive against production n8n data under pressure.

## Alternatives considered

**Backups after the first services (M7+).** Matches "there is something to back
up now". Rejected: every service added before backups exist is unprotected, and
the gate is exactly what stops indefinite deferral.

**Hetzner snapshots only.** Trivial, one click. Rejected as the primary
mechanism: whole-disk images with no file-level restore, no deduplication, no
encryption under your control, and stored with the same provider as the server.
Useful as a pre-change safety net, not as a backup strategy.

**pg_dump to a local directory.** Better than nothing. Rejected: a backup on the
same disk as the data does not survive the failure it exists for.

## Trade-offs

**Gained:** the first real service arrives on a host where data loss is already
a solved problem. The restore path is proven before it is needed.

**Given up:** roughly one hour before n8n runs.

**Explicitly in scope, and easy to miss:** `/opt/life-server/.env`. Per
ADR-0006 that file is not in Git; if it is not in the backup, a total loss
means regenerating every secret and losing every n8n stored credential.

## Consequences

- Backup set: Docker volumes (Postgres data, Redis, app volumes), the repo
  checkout, and `.env`.
- Postgres is dumped with `pg_dumpall` rather than copied at file level — a
  file-level copy of a running database is not consistent.
- `RESTIC_PASSWORD` goes in a password manager immediately. Losing it makes
  every backup permanently unreadable.
- Backup failure must alert. A silently broken backup is worse than none,
  because it is trusted.

## Follow-up

- [x] M5: restic **host package**, not a container — see deviation below
- [x] M5: verify `.env` is in the backup set — asserted on every run
- [x] M5: **rehearse a restore against a throwaway database** — passing
- [x] M5: document the restore procedure step by step — `docs/milestones/M5.md`
- [x] M5: **off-host copy** — two tiers, see below. Restore verified from the
      off-host copy with no server contact. M6 unblocked.
- [ ] M8: alert on backup failure via ntfy
- [ ] optional: automate tier 2 with a cloud remote to remove the freshness caveat

**Deviation, recorded.** This ADR anticipated a restic *container*. M5 runs
restic as a host package under a systemd timer instead: a container would need
the Docker socket plus host mounts to read volumes and dump Postgres, which is a
larger attack surface than a root script on a timer, for no benefit. The intent
of this ADR — scheduled, monitored, encrypted, off-host — is unaffected.

**How the off-host requirement was met (2026-07-30).** Not with the anticipated
cloud repository, but with two tiers:

| Tier | Where | Trigger |
|---|---|---|
| 1 | `/srv/restic` on the server | systemd timer, daily |
| 2 | the operator's laptop, via `make backup-pull` | on demand |

Tier 2 is different hardware, in a different building, on a different provider's
account, so it survives the disk, host and account loss this ADR is concerned
with. It was verified by restoring `.env` and the `pg_dumpall` output from the
laptop copy **with the server uninvolved** — the only test that answers whether
data can actually be recovered.

**Residual risk, accepted knowingly:** tier 2 is manual, so the off-host copy is
only as fresh as the last pull. `make backup-pull-status` exits non-zero once it
is over a week old, making staleness visible instead of silent. A cloud remote
would automate this tier and remains available as a drop-in
(`RESTIC_REPOSITORY=s3:...`) without touching any script.

**The hard gate is satisfied, not waived.** "After M5, no service that stores
data ships until its data is in the backup set" — n8n's data will be in both
tiers from its first backup.
