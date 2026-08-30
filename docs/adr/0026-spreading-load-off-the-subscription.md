# ADR-0026: Spreading agent load off the Pro subscription

- **Status:** Accepted
- **Date:** 2026-08-30
- **Milestone:** M17
- **Builds on:** ADR-0021 (the router), ADR-0018 (why free providers were refused)

## Context

The operator's report: *"every request runs through my claude pro subscription
which eats my whole usage."*

This ADR was referenced by `docker-compose.prod.yml` in three places before it
existed. Writing it down is part of the fix — the reasoning for the `auto`
reversal lived only in a compose comment.

**The routing is not the problem, and that is the trap.** All four agent paths
already point at the router, verified by measurement rather than by reading:

```
$ make verify-subscription-load
  ok    no agent bypasses the router
  ok    4 agent base URLs route through omniroute
  FAIL  tier 2 is NOT keyed (ANTHROPIC_API_KEY empty in .env)
```

paperclip workers, openclaw, hermes and the `subscription` combo all traverse
omniroute. So the compose file reads as correct, reviews as correct, and *is*
correct — and the subscription is still consumed by every single turn.

The cause is one empty variable. `ANTHROPIC_API_KEY=` is blank in `.env`, so
`providers.anthropic-direct` was never provisioned. A router with one tier has
nowhere to route to: **"behind the router" and "billed to the Pro plan" are the
same state today.** ADR-0021 shipped tier 2 "inert until keyed" and it was
never keyed — follow-up item 4 of that ADR, still open.

## Decision

**Key tier 2. Do not add free providers. Make the unkeyed state fail loudly.**

Three parts, in order of how much they matter:

1. **`scripts/omniroute-providers.sh` provisions `anthropic-direct`.** The
   script is the only config surface this service has (OmniRoute reads no
   config file; state lives in SQLite). Tier 2 was documented in
   `compose/omniroute/README.md` but no code ever created it. The connection is
   created `enabled: false` when no key is present, so an unkeyed deploy
   behaves exactly as today rather than turning a clean fallback into an auth
   error.

2. **`make verify-subscription-load`** turns the invisible state into a failing
   check. Local only — no SSH — because the operator's uplink is frequently
   unavailable and this must be diagnosable without it.

3. **`env.example` states the consequence at the variable**, not three files
   away.

## Why not the free providers

The operator explicitly permitted them:

> "an die fremden anbieter ist absolut richtig"
> "nur bei sensiblen daten, also wirklich sensiblen am besten das nicht;
>  aber ich bin recht offen wohin meine daten gehen"
> "also bitte nicht nur meine pro abo belasten"

That instruction is accepted. It cannot be met on this path, for a capability
reason rather than a preference or a data-custody one:

```
400 No target in combo auto supports tool calling; request carried 29 tools
```

**Agent work is tool calling.** A pool that cannot call tools cannot serve these
agents at any capacity. Measured alongside: 463 stream failures from the free
pool against 6 from the subscription in one hour, and a run that hung 62 minutes
because a free provider accepted a request and went silent mid-stream.

So the operator's preference is not overruled — it is inapplicable here. Where
it *does* apply is anything without tools: summarisation, classification,
drafting. That remains worth doing as a per-task choice and needs its own ADR.

## What was NOT done, and why

**Killing or stopping the agents** was the operator's other stated option. Not
taken: it stops the usage by stopping the system, and OpenClaw, Hermes and the
Paperclip board are the point of the host. Rerouting was the other half of the
same instruction and preserves the system. If the intent was in fact to shut the
agents down, `docker compose stop openclaw hermes` does it and nothing here
prevents that.

**Free providers as tier 3.** Refused above on capability, not on taste.

**Shrinking the prompts.** Still worth doing (ADR-0021 said so and it is still
true), but it reduces cost per turn rather than moving where turns are billed.
It does not answer this complaint.

## Trade-offs

**Gained:** the subscription stops being the only place load can land. Tier 2
absorbs 400s and per-model cooldowns instead of failing the run.

**Given up:** tier 2 costs money per token, where the subscription is flat-rate.
At this volume that is a few euros a month — but it is not zero, and it is the
honest price of the operator's actual request. The subscription remains tier 1
and still answers everything it can, so tier 2 is charged only for what tier 1
refuses.

**Unchanged:** the data path is still one named counterparty. ADR-0018's reason
1 and reason 3 continue to hold.

## Consequences

- `ANTHROPIC_API_KEY` moves from optional to **required for the fix to do
  anything**. Without it the system is in exactly its current state, and
  `make verify-subscription-load` now says so.
- One operator action is unavoidable and cannot be automated: obtaining the key.
- `./scripts/omniroute-providers.sh` must be re-run after setting it. It is
  idempotent; re-running is safe.

## Follow-up

- [ ] Operator: set `ANTHROPIC_API_KEY` in `.env`, run the provisioning script.
- [ ] Verify by measurement that tier 2 actually fires: force a 400 at tier 1
      and confirm the turn completes. A keyed provider is not a working one.
- [ ] Add `make verify-subscription-load` to CI so this cannot regress silently.
- [ ] Per-task routing for tool-free work (summarise/classify/draft) to the free
      pool — the part of the operator's instruction that is still achievable.
