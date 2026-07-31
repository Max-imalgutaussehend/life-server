# ADR-0017: Agent sessions run on the operator's machine, not the server

- **Status:** ⚠️ **Superseded by [ADR-0019](0019-agents-run-on-the-server.md)**
  (2026-07-31, same day). The premise below is correct — the Keychain credential
  cannot be copied to Linux — but the conclusion was wrong. Only one question
  was checked: whether the credential could be *copied*. `claude setup-token`
  mints a portable long-lived token, which makes server-side agents possible
  after all, and delivers the all-day operation this ADR explicitly gave up.
  The sandbox reasoning and the ticket-store split carry over unchanged.
- **Date:** 2026-07-31
- **Milestone:** M9

## Context

M9 needs agents that execute code, authenticated by the operator's **Claude
subscription** — there is no API key, and the operator does not want one:

> "all agents need to use claude login, no api ... but they should be able to do
> execute code and everything"

The obvious design puts a Claude Code runner in a container on the VPS beside
Postgres and Paperclip. It does not work, for a reason that is not a matter of
preference.

**Claude Code's OAuth credential is stored in the macOS Keychain**, verified
2026-07-31: `security find-generic-password -s "Claude Code-credentials"`
returns it, and `~/.claude.json` holds only an `oauthAccount` reference, not a
usable token. A Keychain item is bound to the machine and the user's login. It
cannot be copied to a Linux VPS in any supported way.

The workarounds are all worse than the problem:

- **Extract the token and ship it to the server.** This puts a long-lived
  credential to the operator's *entire Claude account* inside the workspace of
  an agent that executes model-chosen code — precisely what the M9 sandbox
  exists to prevent. It also breaks on every token refresh.
- **Log in interactively per session.** Defeats automation, which is the point.
- **Buy an API key.** Explicitly ruled out by the operator.

## Decision

**Agent sessions run on the operator's Mac. The server runs everything else.**

```
Mac (has the Keychain credential)          VPS (has the data)
┌────────────────────────────┐            ┌──────────────────────────┐
│ paperclip-runner           │            │ Postgres                 │
│  ├─ claims a ticket ───────┼──over SSH─►│  tickets, ticket_events  │
│  ├─ claude -p (headless)   │            │                          │
│  └─ writes the result back ┼───────────►│  Caddy, n8n, ntfy, Kuma  │
└────────────────────────────┘            └──────────────────────────┘
```

The ticket store stays on the server — it is the durable, backed-up, shared
state. Only *execution* moves, because only execution needs the credential.

### Why this is better than a compromise, not just a fallback

It is easy to read this as settling. It is not:

1. **The credential never leaves the machine it is bound to.** No token is
   copied, stored, mounted, or transmitted. The strongest possible handling of
   a secret is not handling it at all.
2. **Code execution is not co-located with the data.** An agent on the Mac that
   gets prompt-injected has no route to Postgres beyond the narrow ticket
   interface it is given. On the VPS it would be one Docker network
   misconfiguration away from the database.
3. **Blast radius is a laptop, not the server.** A runaway agent burns local CPU
   and is stopped with Ctrl-C.
4. **It matches how the subscription is licensed** — an interactive tool used by
   a person on their machine, rather than a server daemon impersonating one.

### What is given up

**Agents only run while the Mac is on.** This is a real loss: no overnight or
unattended work. Tickets queue on the server and are picked up on the next run,
so nothing is dropped — but "my life automates itself while I sleep" is not what
this delivers.

That trade is deliberate. The alternative buys unattended execution with the
operator's full Claude credential sitting on an internet-facing host, inside the
one component designed to run untrusted instructions. Not worth it.

If unattended execution later becomes essential, the honest fix is an API key
with its own budget — a new decision superseding this one, not a workaround
bolted onto it.

## Concurrency

**Three sessions at once**, per the operator. Enforced by the runner, because a
subscription has rate limits and an unbounded delegation tree will find them.
The limit is one variable (`PAPERCLIP_MAX_CONCURRENT`), not a constant buried in
code.

## The sandbox still matters

M9 step 2 built `net-agent` and proved 15/15 that a workspace there cannot reach
Postgres, Redis, n8n, Caddy, ntfy or Kuma, has no Docker socket, sees no secrets
and is not root.

That work is **not** wasted. It stands as the boundary for any future
server-side execution — including the API-key design above, should it ever be
needed. `make verify-agent-sandbox` keeps asserting it.

On the Mac the equivalent boundary is different and weaker, and this must be
stated plainly: **a Claude Code session on the Mac runs as the operator.**
Mitigations, in order of what actually helps:

- sessions run in a **dedicated workspace directory**, not the home directory or
  a repository checkout
- `--max-turns` bounds a runaway loop
- **`--dangerously-skip-permissions` is never used** by the runner
- the ticket body is treated as untrusted input, because another agent wrote it

## Consequences

- `paperclip-runner` is a local process, not a container in the prod stack.
- The `paperclip` hostname stays reserved for the eventual web UI, which *is*
  server-side and needs no credential.
- The runner reaches Postgres over SSH, so it needs no new open port and no
  public database exposure.
- `hermes` as a separate service is dropped. The CEO agent is a Claude Code
  session with a role prompt, not a daemon — see `docs/PAPERCLIP-HERMES-BRIEF.md`.

## Follow-up

- [ ] If the Mac-only constraint becomes painful, revisit with a dedicated API
      key and a budget cap, superseding this ADR.
- [ ] Consider a `launchd` agent so the runner starts with the Mac, once the
      loop has proven itself by hand.
