# ADR-0027: No subscription consumption on an idle system

- **Status:** Accepted
- **Date:** 2026-08-30
- **Milestone:** M18
- **Amends:** ADR-0020 (the credential heartbeat), ADR-0026 (tier 2)

## Context

The operator's requirement, stated exactly:

> "ensure none of the agents is using the claude pro subscription to run, no
> heartbeat and nothing. so if i dont use my agents for a day there is no
> consumption in my claude pro sub"

ADR-0026 addressed where *requested* work is billed. This is a different
property: what the system spends when **nothing is requested at all**.

An audit of every model-calling path in the repo found the answer is one
container. The agents themselves are all reactive:

| Path | Trigger | Idle cost |
|---|---|---|
| openclaw | inbound WhatsApp/Telegram, `dmPolicy: allowlist` | none |
| hermes | Paperclip drives it over HTTP/SSE | none |
| paperclip workers | a board item assigned to an agent | none |
| `verify-agent-sandbox.sh` | `make verify-agent-sandbox`, by hand | none |
| **cliproxy-heartbeat** | **`while true` loop, hourly, forever** | **~24 completions/day** |

No cron, no scheduler, no polling loop anywhere else — checked across the
compose file, both agent configs, the Ansible timers (restic backups only), and
the local Hermes install. **The heartbeat was the entire idle bill.**

That it existed at all was deliberate and correct at the time: the Claude OAuth
credential expires in ~7 days, and it expires *silently* — a dead agent loop and
an idle one look identical from outside. ADR-0020 accepted the hourly completion
as the price of catching that (the M10 outage). What ADR-0020 did not weigh is
that this price is paid on days the operator never touches the system.

## Decision

**Keep the monitor. Move the bill off the subscription.** `HEARTBEAT_MODE`,
default `router`:

- **`router`** — a real completion, sent *through omniroute* against the tier-2
  model. Still a genuine round-trip, so it still detects the expiry; the tokens
  land on `ANTHROPIC_API_KEY` instead of the plan.
- **`full`** — the same completion against tier 1 directly. The pre-M18
  behaviour. Opt-in.
- **`off`** — no check, no spend, no monitoring.

An unrecognised value **exits 1** rather than falling back. A typo silently
resolving to `full` would quietly restore the hourly bill.

### The token-free check was tried and REJECTED

An earlier draft of this ADR chose `auth`: `GET /v1/models` with the credential
attached, costing nothing and still separating 2xx from 401/403. It was written,
shipped into this file, and then found to be **worthless**, which is recorded
here so it is not proposed again:

- cliproxy answers `/v1/models` from its **own static config**, never contacting
  Anthropic. (That is exactly why a wrong model id returns 502 rather than an
  upstream error.)
- The credential it validates is `PROXY_API_KEY` — a fixed string in `.env` that
  **cannot expire**. The OAuth credential in the `cliproxy_data` volume, the one
  that expires in ~7 days, is never exercised.

So it would have reported healthy straight through the M10 outage it exists to
catch. `auth` is now rejected with exit 1.

### ⚠️ The honest limitation: `router` depends on tier 2

`router` moves the bill only if there is a tier 2 to move it to. With
`ANTHROPIC_API_KEY` empty, omniroute has one tier, the request falls back onto
the subscription, and **`router` is `full` under a different name** — the same
~24 completions/day this ADR was written to stop.

That is the state the system is in as of 2026-08-30 (ADR-0026, follow-up 4,
still open). Until tier 2 is keyed, **`off` is the only mode that costs an idle
system nothing.** `make verify-subscription-load` fails on the unkeyed-`router`
combination rather than reporting the mode as safe.

## Consequences

- An unused day now costs **zero** subscription usage. This is checked by
  `make verify-subscription-load`, which also guards against a future loop
  reintroducing an unattended model call.
- Credential expiry is detected more weakly. If agents ever fail with auth
  errors that the monitor did not predict, suspect this trade first and set
  `HEARTBEAT_MODE=full`.
- Uptime Kuma's `cliproxy` monitor keeps its meaning ("the credential is
  accepted") but loses "and the model responds".

## Not addressed here

**OpenClaw is pinned to `omniroute/cliproxy/claude-sonnet-5`** — tier 1 by name.
When you *do* use it, it bills the subscription by construction, and ADR-0026's
tier 2 cannot catch it because nothing about that model id fails over. That is
about used-system cost, not idle cost, so it is out of scope here — but it is
the next thing to change if subscription usage is still climbing while you use
your agents normally.

## Follow-up

- [ ] Verify on the server that `/v1/models` returns 401/403 with a bad
      credential. If it returns 200, this monitor is decorative.
- [ ] Consider whether OpenClaw's pinned model should become the `subscription`
      combo or a tier-2-capable id.
