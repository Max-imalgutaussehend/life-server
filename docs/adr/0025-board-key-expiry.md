# ADR-0025: The board key expires; the agent key does not

- **Status:** Accepted
- **Date:** 2026-08-26
- **Milestone:** M16

## Context

OpenClaw reported which Paperclip endpoints it could not reach with its agent
key: `/api/adapters`, `/api/companies/.../members`, and pausing, resuming or
deleting agents — all answered with `403 Board access required`.

The agent concluded that a browser login was the only way. That was wrong:
Paperclip has a `board_api_keys` table, so board-level access has a
non-interactive path.

## Decision

**Issue a board key, and give it a 30-day expiry.**

The expiry is the whole substance of this ADR. Everything else follows from
ADR-0023, where full host access was already granted and argued.

### Why an expiry, when the agent key has none

The two keys are not comparable, and the difference is worth stating:

| | agent key | board key |
|---|---|---|
| Bound to | one agent row | the operator's user id |
| Acts as | that agent | **the operator** |
| Revoking | `revoked_at` on its own row | invalidates operator-level access |
| Blast radius | that agent's work | agent lifecycle, members, adapters |

An agent key that leaks costs one agent. A board key that leaks acts as the
person. It lives in a container that executes model-chosen code and holds the
Docker socket, so "it will be noticed and revoked" is not a mitigation that
can be relied on — the same container could remove the evidence.

An expiry is a mitigation that does not depend on anyone noticing. If the key
is forgotten, it stops working. Renewal is then a conscious act rather than a
default.

## Alternatives considered

**No board key; the operator performs admin actions.** Safest, and what was
recommended. Rejected: the operator asked for it explicitly after being shown
this trade-off.

**No expiry, matching the agent key.** Simpler, one less thing to renew.
Rejected for the asymmetry above: this key acts as a person, not as a service.

**A shorter expiry (7 days).** Better security, worse ergonomics — a key that
expires mid-task while the operator is away turns a working system into a
puzzle. 30 days is long enough not to interrupt work and short enough that a
forgotten key does not become permanent.

## Consequences

- `PAPERCLIP_BOARD_TOKEN` in `.env`, `:-` not `:?` — an expired key must
  degrade to "cannot administer" rather than "container will not start".
- **It will stop working around 2026-09-25.** Symptom: 403 on admin
  endpoints, while ordinary agent work continues. That is the design, not a
  regression.
- Renewing means inserting a new row in `board_api_keys` and revoking the old
  one. There is no rotation tooling; that is acceptable for something meant to
  be renewed deliberately.

## Follow-up

- [ ] Decide at expiry whether the agent still needs board access, rather than
      renewing reflexively.
- [ ] If it is renewed twice, reconsider the scoped alternative: most of what
      it unlocks is agent lifecycle, which could be a narrow endpoint instead
      of operator-level access.
