# omniroute — the fallback model router

JSON takes no comments and the router validates strictly, so the reasoning
behind `omniroute.json` lives here. Same arrangement as `openclaw.json`, whose
explanation sits in its entrypoint.

See **ADR-0021** for why this service exists at all, and why it is a documented
reversal of ADR-0018 rather than a neutral addition.

## The shape of the config

**`providers.claude-subscription` is tier 1 and is not optional.** The
subscription answers every request it can. This router exists only to catch the
ones it refuses — it is a safety net, not a replacement. If tier 1 is ever
removed, every agent turn silently starts costing money at a third party, which
is precisely the failure mode ADR-0018 warned about.

**`providers.anthropic-direct` ships `"enabled": false`.** It is the recommended
tier 2 and is deliberately inert until a key exists in `.env`. Enabling a
provider with no credential would turn a clean 400 into an auth error and make
the real cause harder to see. To activate:

1. put `ANTHROPIC_API_KEY=sk-ant-…` in `.env` on the server
2. flip `"enabled"` to `true` here
3. redeploy

**Why an API key and not one of the 90+ free tiers.** The free providers are the
reason this router is attractive and the reason it is dangerous. These requests
carry the operator's uni, work and job-application context. "Whichever of 339
vendors had quota left this hour" means that question — *where did my job
application go?* — stops having an answer. A direct Anthropic key costs a few
euros a month at this volume and keeps the data path to exactly one named
counterparty.

Nothing prevents adding free providers later. Do it as a deliberate edit with
its own reasoning, not as a default that arrives unnoticed.

## `retry.retryOnStatus` includes 400, which is unusual

400 normally means "malformed request, retrying is pointless". Here it is the
*specific symptom being routed around*: the subscription proxy returns 400 when
the request exceeds an account-wide token budget (measured 2026-08-24 — 3 tools
/ 26,380 B fails, 2 tools / 25,910 B passes). The same request against a
provider without that ceiling succeeds.

The cost of this choice: a genuinely malformed request now costs two upstream
calls instead of one. Acceptable at this volume, and the circuit breaker caps
the damage.

## What is switched off, and why

| Subsystem | Why off |
|---|---|
| `dashboard` | A Next.js app — the single largest memory cost in the image. Provider config is declared in this file instead, which also keeps it reviewable in Git. |
| `memory` | FTS5 + Qdrant vector store. OpenClaw already keeps conversational state; a second copy of the operator's private messages in a new component is a liability, not a feature. |
| `semanticCache` | Embeddings on every request, for a few messages a day. Pure overhead at this volume. |
| `telemetry` | Nothing about this workload should leave the host uninvited. |
| `stealth` | TLS-fingerprint spoofing exists to make an automated client look like a browser to providers that forbid automated use. That defeats a counterparty's terms rather than working within them — the same objection ADR-0018 raised against option B. |

## ⚠️ Unverified at authoring time

The config **key names above were not confirmed against upstream documentation.**
The authoring host had no route to it: the operator's uplink was IPv6-only and
both the server and github.com are reachable only over IPv4.

This matters because unknown keys in a config file are usually ignored rather
than rejected. A silently-ignored `"enabled": false` means the subsystem is
still running and the memory limit gets hit instead.

**The first deploy must therefore verify by measurement, not by reading:**

```sh
docker compose -f compose/docker-compose.prod.yml logs omniroute | head -40
docker stats --no-stream prod-omniroute
docker exec prod-omniroute wget -qO- http://127.0.0.1:20128/v1/models
```

If the dashboard still answers on `:20128/dashboard`, the trimming did not take
effect and the key names need correcting against the real schema.
