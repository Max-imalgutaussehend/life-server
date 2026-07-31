# ADR-0018: A WhatsApp assistant, and why it does not need a second LLM

- **Status:** Proposed — needs one decision from the operator (see the end)
- **Date:** 2026-07-31
- **Milestone:** M10

## Context

The operator wants to talk to the system from WhatsApp:

> "so paperclip ui definitely hosted as subdomain AND an assistant bound to
> whatsapp with possibility to talk"

and raised an implementation idea:

> "llm wise we would need something free, projects like omni channel who route
> on 70+ free providers till the free is empty"

Two separate questions hide in there: **how do messages get in and out**, and
**what thinks about them**. They have different answers and deserve to be
decided separately.

## The second question first: what thinks about the message

**Nothing new needs to.** The system already has a CEO agent — a Claude Code
session on the operator's Mac (ADR-0017) — that turns a sentence into tickets.
A WhatsApp message is a sentence. The path is:

```
WhatsApp message → a ticket row → the existing CEO agent → child tickets
                                                        ↓
WhatsApp reply   ←  the bridge polls for results  ←  workers finish
```

The bridge is a **transport**, not an intelligence. It needs no model at all.

### Why not the free-provider-routing idea

Routing across dozens of free LLM providers is a real technique, and for a
throwaway side project it is a reasonable one. For this system it is the wrong
trade, for three reasons worth stating plainly rather than dismissing:

1. **The data is the problem, not the cost.** These messages are about uni,
   work, job applications and personal life. Free-tier providers are free
   because the traffic is worth something to them — commonly training rights,
   often indefinite retention, sometimes both. "Whichever of 70 vendors had
   quota left this hour" means the operator cannot answer *where their job
   application went*, which is precisely the question ADR-0004 and ADR-0006
   exist to keep answerable.

2. **It solves a problem this system does not have.** The subscription already
   pays for the reasoning, and it happens on the operator's own machine. Adding
   a second, weaker, unpredictable model to do the same job is more moving parts
   for a worse result.

3. **Quality is load-bearing here.** The CEO's decomposition is what makes the
   ticket system work at all. A degraded model produces vague tickets, and vague
   tickets produce agents that do the wrong thing confidently.

**If a small local model is ever wanted** — to classify "is this a task or just
chatter?" before waking the CEO — the honest answer is a 1–3B model in Ollama on
the VPS. Free, private, and good enough for classification. That is a later
optimisation, not a dependency.

## The first question: how messages get in and out

This is the real decision, and it is a **trust** decision more than a technical
one.

| Option | What it costs | What it risks |
|---|---|---|
| **A. WhatsApp Business Cloud API** (Meta, official) | free tier far beyond one person's use; needs a Meta developer account and a number | nothing to the personal account — it is the supported path |
| **B. A library driving WhatsApp Web** (whatsapp-web.js, Baileys) | free, no Meta account, uses the personal number | **against WhatsApp's terms; the account can be banned.** Also breaks whenever WhatsApp changes its web client |
| **C. Signal or Telegram instead** | genuinely free, official bot APIs, no ban risk | not WhatsApp, which is what was asked for |

**Recommendation: A.** The free tier is far beyond one person's usage, it does
not put the operator's personal WhatsApp account at risk, and it does not break
on a Tuesday because Meta shipped a web update. Option B looks free right up
until the account it is attached to is the one the operator actually uses.

## The consequence either option forces

**Inbound WhatsApp means the first genuinely public endpoint.** Everything today
sits behind Cloudflare Access; a webhook cannot, because Meta's servers cannot
complete an Access login — the same problem as the ntfy phone app, and solved
the same way: a bypass on exactly one path.

So the bridge gets:

- a **path-scoped Access bypass** (`/webhook/whatsapp`), never a hostname bypass
  — see [[cloudflare-access-path-scoping]] in the M8 notes for why that
  distinction is easy to get wrong
- **signature verification** on every request (Meta signs with
  `X-Hub-Signature-256`); an unsigned request is dropped before it is parsed
- an **allowlist of one phone number**. A webhook anyone can reach is a webhook
  anyone can task an agent through, and those agents execute code
- **rate limiting**, because the ticket queue drives real work

## Consequences

- A new service, `hermes` — the name finally used, as a message bridge rather
  than the agent daemon ADR-0017 made unnecessary.
- It holds a Meta app secret and token: new secrets in `.env` and SOPS.
- It joins `apps` and `data`. Not `agent` — it holds credentials.
- It never calls an LLM. If that ever changes, it needs a new ADR.

## The one decision needed from the operator

**Meta Business API (recommended) or an unofficial library?** The first needs a
Meta developer account and about fifteen minutes of dashboard work. The second
needs nothing, but risks the account.

Nothing is built until this is answered, because the two produce completely
different services.
