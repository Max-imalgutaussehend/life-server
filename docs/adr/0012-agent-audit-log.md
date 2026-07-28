# ADR-0012: Agent actions with external effect are written to an append-only audit log

- **Status:** Accepted
- **Date:** 2026-07-28
- **Milestone:** M0 (schema), M2 (log rotation), M9 (volume + enforcement)

## Context

This host will run autonomous agents that take actions in the world: sending
email, calling APIs, writing to third-party systems. When something goes wrong
— or when it simply needs explaining — the question is "which agent did what,
when, on what input, with what result?"

`docker logs` cannot answer that reliably. Container logs rotate, are lost when
a container is recreated, are unstructured, and vanish precisely when an agent
crashes — which is when the record matters most.

This is not a logging concern. It is an audit trail, and it has different
requirements.

## Decision

**Actions with external effect are written to an append-only audit log on a
dedicated volume, separate from container stdout.**

- Location: `/opt/life-server/data/audit/` (own volume, backed up from M5)
- Format: newline-delimited JSON, one object per action
- Retention: never rotated by size; archived monthly, kept indefinitely
- Written by the agent at the moment of action, not reconstructed from logs

Schema:

```jsonc
{
  "ts": "2026-07-28T21:52:03.412Z",  // ISO 8601, UTC, millisecond precision
  "agent": "hermes",                  // which agent
  "run_id": "01J...",                 // ULID, groups actions in one run
  "action": "email.send",             // dotted verb, stable vocabulary
  "target": "recipient@example.com",  // what was acted upon
  "input_digest": "sha256:...",       // hash of the prompt/input, not the text
  "outcome": "success",               // success | failure | refused
  "detail": "message-id: <...>",      // human-readable, may be empty
  "duration_ms": 1240
}
```

`input_digest` rather than the prompt itself: prompts contain personal data, and
this file is not encrypted. The hash proves which input produced the action
without storing it. Agents that need full prompt retention write it to their own
storage with their own retention policy.

Separately, and independently: Docker's `json-file` driver gets size limits in
M2 (`max-size: 10m`, `max-file: 3`) so container logs cannot fill the disk.
That is disk hygiene, not audit.

## Alternatives considered

**Container stdout plus Loki.** The conventional stack. Rejected as the
mechanism of record: Loki is a query layer over logs that may already be
incomplete. Loki remains a good idea later, reading this log as one of its
sources.

**Database table.** Queryable, transactional. Rejected: an audit record must
survive the database being down or corrupted, and that is one of the scenarios
worth auditing.

**Nothing until an agent exists (M9).** Rejected: the schema must be fixed
before the first agent writes to it. Unifying divergent formats afterwards is
the expensive path.

## Trade-offs

**Gained:** a durable answer to "did Hermes send that email?" that survives
container recreation, crashes and log rotation.

**Given up:** agents must be written to emit these records — it is a contract
they must honour, not something the platform can impose. An agent that does not
write to the log produces no audit trail, and nothing detects that
automatically.

**Privacy note:** hashing inputs is a deliberate limitation. It means the log
cannot answer "what exactly was the agent told?" — only "was it told this?",
given a candidate. That trade favours not accumulating personal data in an
unencrypted file.

## Consequences

- The volume is created in M9 but the schema is fixed here, so the first agent
  written has a target to hit.
- Backed up from M5 onward as part of `/opt/life-server/data/`.
- Append-only by convention and file permissions; not cryptographically
  tamper-evident. Anyone with root can alter it. Hash-chaining is a possible
  later addition if that threat becomes relevant.

## Follow-up

- [ ] M2: Docker log rotation (`max-size: 10m`, `max-file: 3`)
- [ ] M5: include `data/audit/` in the backup set
- [ ] M9: create the volume, implement writing in Hermes
- [ ] M9: define the `action` vocabulary as agents are built
