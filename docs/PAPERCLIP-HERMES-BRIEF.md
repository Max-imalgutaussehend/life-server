# Paperclip and Hermes — what they are (operator brief)

Captured 2026-07-30 from the operator's description, before any code exists.
This is a **requirements record, not a design**. It exists so M9 starts from
what was actually asked for rather than from my assumptions.

## In the operator's words

> "paperclip wird meine agentic ide auch über web hosting um mit genau diesem
> claude llm zu reden. paperclip stellt einen ceo agent (eine hermes instanz)
> und hier haben wir dann eine multi agent ticket based struktur die mein leben
> in gewisser weise automatisiert für uni, arbeit (connection mit meinem work
> agent, job suche, persönliches, projekte, …)"

## What that means, as I read it

**Paperclip** — a web-hosted agentic IDE. Browser-accessible, talks to Claude
(this model). It is the human interface: where the operator writes, reviews and
steers.

**Hermes** — the agent runtime. Paperclip instantiates one Hermes as a **CEO
agent**, which decomposes work and delegates to further Hermes instances.

**The coordination model is ticket-based.** Agents do not chat freely; they
create, assign and close tickets. That is the substrate that makes multi-agent
work auditable and resumable.

**Life domains in scope:** university, work (including a connection to a
separate existing "work agent"), job search, personal, projects.

## Why this is bigger than M9 as currently written

The roadmap lists M9 as "Paperclip, Hermes, audit log, dev stack" — one
milestone. What is described here is a **multi-agent operating system**: an IDE,
an agent runtime, a ticket system, a delegation hierarchy, and integrations with
an external agent. That is several milestones, and the ordering matters more than
the speed.

I am flagging this rather than silently building a fraction of it and calling M9
done.

## What the existing infrastructure already provides

| Need | Status |
|---|---|
| Hostnames `paperclip` / `hermes` | ✅ reserved in `services.yml` |
| Postgres database + role each | ✅ provisioned in M4, isolation verified |
| Redis for queues | ✅ running; n8n does not use it, so it is free |
| Ingress + TLS | ✅ tunnel + Caddy, route generated on `enabled: true` |
| Auth at the edge | ⚠️ needs an Access policy per hostname |
| Backups covering their data | ✅ any Postgres database is in `pg_dumpall` |
| Monitoring | ✅ add to `seed-monitors.sh` when they exist |

So the **platform** is ready. What is missing is the application itself.

## Open questions that change the design materially

These need answers before code, because guessing wrong is expensive:

1. **Ticket store — Postgres or an existing tool?** A `tickets` table in the
   `hermes` database is simplest and fully under our control. Alternatively n8n
   or a real issue tracker. Recommendation: Postgres, because agents need
   transactional state, not a UI.

2. **Where does agent execution happen?** A Hermes instance calling the Anthropic
   API is cheap and stateless. One that *runs code* needs a sandbox, and that is
   a serious security boundary on a host that also holds your credentials.
   Which is it?

3. **The Anthropic API key** — a new secret class. It is spendable, so it needs a
   budget limit and, ideally, its own key per agent so one runaway loop is
   attributable and revocable.

4. **What is the "work agent" and how does it connect?** Inbound webhook,
   outbound polling, or shared queue? This determines whether anything new has to
   be publicly reachable.

5. **Does Paperclip execute code the operator writes?** If yes, it is effectively
   remote code execution behind a login, and it belongs in its own isolation
   boundary — not on the same Docker host as Postgres, or at minimum not on the
   `data` network.

6. **Build order.** My recommendation: ticket schema first, then one Hermes that
   can only read/write tickets, then delegation, then Paperclip's UI. That way
   there is something testable at every step, and the agent layer is proven
   before a UI hides it.

## Recommended next step

Answer questions 1–3 (store, execution model, API key handling). That is enough
to design the ticket schema and a first Hermes that does real work without any
code-execution risk. Paperclip's UI can follow once the agent layer is proven.

Until then M9 stays blocked, deliberately.
