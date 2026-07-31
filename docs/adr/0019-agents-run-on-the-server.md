# ADR-0019: Agents run on the server, using a long-lived subscription token

- **Status:** Accepted
- **Date:** 2026-07-31
- **Milestone:** M10
- **Supersedes:** [ADR-0017](0017-agents-run-on-the-operator-machine.md)

## Context

ADR-0017 put agent execution on the operator's Mac. Its reasoning was that
Claude Code's credential lives in the macOS Keychain and cannot be copied to a
Linux host — which is true, and which was verified. Its **conclusion** was
wrong, because only one question was checked: whether the credential could be
*copied*. Never whether Claude Code could authenticate on Linux by another
route.

It can:

```
$ claude setup-token --help
Set up a long-lived authentication token (requires Claude subscription)
```

That is a portable token, not a Keychain item. `claude auth status` confirms the
operator holds `subscriptionType: pro` with `authMethod: claude.ai`, so this
path is available to them.

ADR-0017's stated cost turned out to be the thing the operator actually cares
about:

> "i wanted something living 'all day'"

A Mac-bound runner cannot deliver that. A closed laptop is a stopped system, and
the WhatsApp assistant in ADR-0018 is worthless if it only answers when the
operator is already at their desk.

## Decision

**Agent sessions run on the server, authenticated by a long-lived subscription
token.**

The M9 sandbox is unchanged, and becomes load-bearing rather than theoretical:
sessions run in a container on `net-agent`, which `verify-agent-sandbox.sh`
proves (15/15) cannot reach Postgres, Redis, n8n, Caddy, ntfy or Kuma, has no
Docker socket, sees no `.env` or age key, and is not root.

## The caveat, stated plainly

**This is a real increase in risk, and it should not be glossed over.**

On the Mac, the credential was a Keychain item on a machine that is usually
closed, behind a login, on a home network. On the server it becomes a
long-lived token on an internet-facing host, inside the one component whose
entire job is executing instructions chosen by a language model.

The sandbox contains what an agent can *reach*. It cannot contain the token
itself, because the agent process must read it in order to work. So:

**A successful prompt injection can use the subscription.** Not read the
database, not reach n8n, not touch the age key — those are blocked and tested.
But it could burn quota, or make requests the operator did not intend.

This is accepted because:

1. **The blast radius is bounded and recoverable.** A leaked token is revoked at
   claude.ai and reissued in a minute. Compare that with what the sandbox *does*
   protect: Postgres holds the ticket history, n8n holds API keys for every
   service it integrates with, the age key decrypts every secret in the
   repository. None of those are reachable from a session.
2. **The token is the only secret in the workspace.** There is deliberately
   nothing else there worth stealing, which is what makes egress acceptable.
3. **The alternative was not "safer", it was "off".** ADR-0017 traded away the
   entire point of the system — unattended operation — to reduce risk on the
   single most replaceable credential in it.

**Mitigations that are actually applied**, not aspirational:

- the token lives in `.env` / SOPS like every other secret, mounted only into
  the agent container
- `--permission-mode acceptEdits`, never `bypassPermissions` — file edits are
  auto-approved inside the workspace, nothing else is
- `--max-turns` bounds a runaway loop; `PAPERCLIP_MAX_CONCURRENT=3` bounds
  parallelism
- each session gets a **fresh workspace directory**, destroyed afterwards
- the worker prompt states that the ticket body is untrusted data written by
  another agent, not instructions to follow

**The honest residual risk:** a determined prompt injection that only wants to
consume quota will succeed until the operator notices. There is no mitigation
short of not running agents unattended, which is the thing being asked for.

## What ADR-0017 got right and keeps

- The **ticket store stays on the server** as the durable, backed-up state.
- The **sandbox boundary** and its verification script are unchanged.
- Agents reach the database through a narrow interface, never a connection
  string handed to a session.
- `hermes` is still not an agent daemon. It is the WhatsApp bridge (ADR-0018);
  the CEO remains a `claude -p` session with a role prompt.

## Consequences

- `CLAUDE_CODE_OAUTH_TOKEN` becomes a new secret in `.env` and `secrets.enc.env`.
- `scripts/paperclip-runner.sh` gains a container mode; the Mac path stays
  supported for development and as a fallback if the token is revoked.
- The runner becomes a long-running service, so it needs a restart policy and a
  monitor — an agent loop that has silently died looks exactly like an idle
  queue.
- `make verify-agent-sandbox` moves from nice-to-have to **precondition**: it
  must pass before the runner is deployed, because it is now the only thing
  standing between a prompt-injected session and the rest of the host.

## The one step the operator must run

`claude setup-token` is interactive and mints a credential to their account. It
is not something an assistant should run on their behalf:

```bash
claude setup-token          # then store the token it prints
```

## Follow-up

- [ ] Operator: generate the token
- [ ] Add an Uptime Kuma monitor for the runner — a dead agent loop is
      indistinguishable from an empty queue
- [ ] Revisit if quota consumption ever looks wrong; revocation is one click
