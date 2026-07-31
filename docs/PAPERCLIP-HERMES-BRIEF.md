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

## Answered 2026-07-31

> "all agents need to use claude login, no api. if not possible with hermes then
> just claude code & paperclip, but they should be able to do execute code and
> everything, tickes is done by paperclip the framework (i only have my claude
> subscription, nothing else)"

**1. Auth: Claude subscription only. No API key.** This is the binding
constraint and it decides the architecture.

A subscription authenticates **Claude Code** through an interactive OAuth login.
It is not a credential a daemon can present on a server to call the Anthropic
API programmatically. So "Hermes as a long-running service that calls the API in
a loop" is not buildable under this constraint — not disallowed by taste, simply
without a mechanism.

The operator already accepted the consequence: *"if not possible with hermes then
just claude code & paperclip"*.

**2. The runtime is therefore Claude Code itself.** It runs headless (`claude -p`),
authenticates with the subscription, and already has tool use, file editing and
code execution. Paperclip invokes Claude Code sessions rather than reimplementing
an agent loop against an API that cannot be reached.

**3. Tickets belong to Paperclip**, as the framework — not a separate Hermes
service. Postgres remains the store (the `paperclip` database and role were
provisioned in M4), but the schema and lifecycle are Paperclip's.

**4. Agents execute code — "everything".** Accepted as a requirement, and it is
the single most consequential answer here. See the boundary below.

## The security boundary this forces

An agent that executes arbitrary code, driven by a model, on the host that also
holds Postgres, `.env`, the age key and the backup repository, means **any prompt
that reaches it can read every secret the system has.** Not a hypothetical: it is
the plain consequence of code execution plus co-location.

So M9 gets a real boundary, not a Docker network label:

| Rule | Reason |
|---|---|
| Agent workspaces run as a **non-root user in their own container**, one per session | a compromised session is not a compromised host |
| That container joins **neither `data` nor `edge`** | no route to Postgres, Redis or the tunnel |
| **No bind mount** of the repository, `.env`, `~/.config/sops`, or the Docker socket | the socket in particular is root on the host, trivially |
| Database access, if ever needed, goes through an **explicit API on the `apps` network** — never a direct connection string | the agent gets an interface, not credentials |
| Egress is allowed (Claude Code needs it) but the workspace holds **no long-lived secret** worth exfiltrating | limits the blast radius of what egress can carry out |

**The unresolved piece:** Claude Code's OAuth session lives on the machine where
the login happened. Running it inside a throwaway container means either mounting
that credential in (which contradicts the table above) or logging in per session
(which is interactive, and defeats automation). This is the first thing M9 has to
solve, and it is a design question, not an implementation detail.

## Still open

- **The "work agent"** — what it is, and whether it connects inbound (webhook),
  outbound (polling), or via a shared queue. Determines whether anything new must
  be publicly reachable. Nothing is built for it until answered.
- **Concurrency and cost** — how many agent sessions may run at once. A
  subscription has rate limits, and an unbounded delegation tree will find them.

## Resolved 2026-07-31 (second round)

> "just do what you would recommend, do not think about the working agent, just
> get the setup with the paperclip claude code ceo agent, finish everything"
> — and, separately: "around 3 at once"

Both questions above are now closed:

- **The work agent is out of scope.** Nothing built, no hostname reserved.
- **Concurrency is 3**, enforced by the runner.

Two further decisions followed:

- **Hermes as a separate service is dropped.** The CEO is a Claude Code session
  with a role prompt, not a daemon. A `hermes` container would have had nothing
  to run.
- **Execution moved to the Mac** ([ADR-0017](adr/0017-agents-run-on-the-operator-machine.md)),
  because Claude Code's OAuth credential is macOS-Keychain-bound and cannot be
  copied to the VPS. This was the last blocking unknown, and it was settled by
  checking rather than guessing: `security find-generic-password -s "Claude
  Code-credentials"` returns it, while `~/.claude.json` holds only an account
  reference.

Steps 1–4 are built and proven end to end — see
[`docs/milestones/M9.md`](milestones/M9.md).

## Build order

1. Ticket schema in the `paperclip` database — testable with `psql`, no agents.
2. The sandbox container and its constraints — provable by *trying* to reach
   Postgres from inside it and failing.
3. Paperclip invoking one Claude Code session against one ticket.
4. Delegation (a session that creates tickets for other sessions).
5. The web UI last.

Each step is verifiable before the next hides it. Step 2 comes before any agent
runs, because retrofitting an isolation boundary under a running system is how
boundaries end up with holes.
