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

- [ ] M5: restic container and repository
- [ ] M5: verify `.env` is in the backup set
- [ ] M5: **rehearse a restore against a throwaway database**
- [ ] M5: document the restore procedure step by step
- [ ] M8: alert on backup failure via ntfy
