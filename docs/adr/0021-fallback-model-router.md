# ADR-0021: A fallback model router, and the part of ADR-0018 it reverses

- **Status:** Accepted
- **Date:** 2026-08-24
- **Milestone:** M13
- **Supersedes in part:** ADR-0018 ("why it does not need a second LLM")

## Context

OpenClaw stopped being able to think on 2026-08-24. Not gradually — every agent
turn returns HTTP 400 from the subscription proxy, which OpenClaw surfaces to
the operator as "your API key has run out of credits". That message is false;
a minimal request succeeded in the same minute.

The real ceiling was found by bisection on a captured request:

| tools | bytes | result |
|---|---|---|
| 2 | 25,910 | 200 |
| 3 | 26,380 | **400** |

Hermes, through the same proxy in the same hour, tipped at 31,032 / 31,339 B
instead. Two prompts, two different byte thresholds — so this is a **token**
budget, not a byte one, and a token-dense prompt hits it sooner.

Everything inside the proxy was tried first, and each was ruled out by test
rather than by reasoning:

- fewer tools — each tool passes alone; only combinations fail
- removing the 30+ skill catalogue — cut 5,013 B, still 400
- all four models (sonnet-5, sonnet-4-6, opus-4-7, fable-5) — all 400
- the native `/v1/messages` endpoint instead of `/v1/chat/completions` — 400

The ceiling is account-wide and protocol-independent. What remains of the prompt
is ~17.2 KB of identity, safety and behaviour sections with no large block left
to cut. **The floor of a working OpenClaw is above the ceiling of this proxy.**

This is exactly the risk ADR-0020 accepted in writing: "a third-party wrapper
around an OAuth flow Anthropic can change without notice." It changed.

## Decision

**Put a router in front of the model providers, with the subscription as tier 1
and a direct provider as tier 2. Route around the 400 instead of trying to fit
underneath it.**

```
openclaw ──> omniroute ──tier 1──> cliproxy ──> Claude subscription
                       └─tier 2──> api.anthropic.com   (inert until keyed)
```

The router is OmniRoute, self-hosted: MIT-licensed, Node + SQLite, one process,
no database dependency of its own. It runs in the `agent` network, reachable by
OpenClaw and nothing else.

Four properties make this acceptable rather than merely convenient:

1. **The subscription is still primary.** Tier 1 answers every request it can.
   The router catches refusals; it does not replace the credential ADR-0020
   established. Nothing that works today takes a different path tomorrow.

2. **Tier 2 is one named counterparty, not a pool.** OmniRoute's headline
   feature is auto-fallback across 339 providers, 90+ of them free tier. That
   feature is **not used.** See the reversal section below.

3. **The expensive half is switched off.** Dashboard (a Next.js app), vector
   memory (Qdrant), semantic cache and telemetry are all disabled. What is kept
   is routing, tiered failover and circuit breaking.

4. **Config is declared in Git, not clicked in a UI.** Upstream's intended
   workflow is the dashboard; provider state then lives only in SQLite on a
   volume. `compose/omniroute/omniroute.json` is the source instead — ADR-0014's
   principle applied by hand, since this service is deliberately not in the
   generated registry.

## What this reverses, stated plainly

ADR-0018 considered this exact shape and rejected it:

> "Routing across dozens of free LLM providers is a real technique... For this
> system it is the wrong trade."

Its three reasons were: the data is the problem not the cost; it solves a
problem this system does not have; quality is load-bearing.

**Reason 2 is no longer true.** The system *does* now have the problem. In July
the subscription answered every request; today it refuses OpenClaw's smallest
workable prompt. ADR-0018 was written against a working proxy.

**Reasons 1 and 3 remain true, and are honoured rather than overridden.** They
are the reason tier 2 is a single direct API key and not the free-provider pool
that makes OmniRoute attractive in the first place. These messages carry uni,
work and job-application context; "whichever of 339 vendors had quota left this
hour" means the question *where did my job application go* stops having an
answer, and that is precisely what ADR-0004 and ADR-0006 exist to keep
answerable.

So: the mechanism ADR-0018 rejected is adopted. The reason it was rejected is
not. If free providers are ever added to `tiers`, this ADR stops covering the
decision and a new one is needed.

## Alternatives considered

**A direct Anthropic API key, no router.** Fewest moving parts, and honestly the
better engineering answer: no third party in the path, no new component, the
400 disappears. Rejected only because the operator asked for the router
explicitly after being shown this comparison. **It remains the recommended
fallback if OmniRoute proves unreliable** — the key is already the tier 2
provider, so removing the router is a one-line change to `OPENAI_BASE_URL`.

**OpenRouter.** A mature, single, well-known counterparty. Genuinely close on
merit; loses to a direct key on data path (one hop instead of two) and to
OmniRoute on the operator's stated preference for self-hosting.

**OpenClaw as courier only** — no reasoning, just message transport to an agent
elsewhere. Preserves the single-credential design completely. Rejected: it makes
the WhatsApp assistant a relay rather than an assistant, which is not what was
asked for.

**Waiting for the ceiling to lift.** Free. Rejected: it is an undocumented
third-party limit that arrived without notice and may leave the same way. The
system should not be blocked on someone else's unannounced change.

## Trade-offs

**Gained:** OpenClaw can think again. A provider outage or a policy change at
one counterparty no longer takes the assistant offline.

**Given up:**

- **A second unsupported dependency.** ADR-0020 named CLIProxyAPI as "the one
  component with no support contract". There are now two, chained — and a
  failure in the router looks identical to a failure in the proxy from
  OpenClaw's side.
- **Verifiability, at authoring time.** The upstream repo could not be read: the
  operator's uplink was IPv6-only and both the server and github.com are
  IPv4-only. Everything about OmniRoute's behaviour here comes from its own
  marketing page. Config key names, the npm version and the memory figures are
  therefore **unverified** and marked as such in every file that carries them.
  The first deploy must confirm them by measurement.
- **A wider data path, if tier 2 ever fires.** Today the subscription sees
  everything. With tier 2 keyed, refused requests go to the Anthropic API under
  a different commercial agreement. One counterparty, two relationships.

**Not gained:** this does not fix the token ceiling. OpenClaw's prompt is still
too large for the subscription proxy, and every fallback request costs money at
tier 2. Shrinking the prompt remains worth doing.

## Consequences

- `.env` gains `OMNIROUTE_API_KEY` (required) and `ANTHROPIC_API_KEY`
  (optional; tier 2 stays inert without it).
- `OPENAI_BASE_URL` for OpenClaw now points at the router. cliproxy is
  unchanged and still serves Hermes directly.
- The router joins `agent` only — never `data`, never `apps`.
- Its `/v1` is gated by `OMNIROUTE_API_KEY`. An ungated router on `agent` would
  let a prompt-injected session spend provider quota or read provider keys back
  out.
- `retry.retryOnStatus` includes **400**, which is normally wrong. Here 400 is
  the specific symptom being routed around. Cost: a genuinely malformed request
  makes two upstream calls.

## Follow-up

- [ ] M13: verify the disabled-subsystem key names against the real schema, and
      measure actual RSS. If the dashboard still answers, the trimming failed.
- [ ] M13: pin `OMNIROUTE_VERSION` to a version confirmed to exist on npm.
- [ ] M13: add an Uptime Kuma monitor for the router, in the shape of
      cliproxy-heartbeat — a healthy port does not prove routing works.
- [ ] Decide whether tier 2 is keyed at all, or whether the router runs with
      tier 1 alone until a 400 actually costs something.
- [ ] Revisit if the subscription ceiling lifts: the router becomes removable.
