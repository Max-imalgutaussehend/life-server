# ADR-0024: A courier, so agents can reach the operator

- **Status:** Accepted
- **Date:** 2026-08-26
- **Milestone:** M16

## Context

Paperclip is pull-only. The CEO agent could think, read the board and close
tickets, but it had no way to tell a human anything between runs — the
operator had to go and look. Asked for the missing half, they described it
precisely:

> "ich will, dass openclaw easy mit den anderen agents reden kann aber ihm
> keine zuweisen, vielleicht für den max ceo (hermes) als assistenz damit er
> mit mir kommunizieren kann"

A messenger, not another worker.

## The obvious implementations, and why both were wrong

**Register OpenClaw as a Paperclip agent.** It already holds the WhatsApp
session, so the board could simply assign it work. Rejected: OpenClaw holds
the Docker socket (ADR-0023). A ticket typed into a web form would become a
task for something with host root, and the operator had explicitly said "ihm
keine [Tickets] zuweisen".

**Give Hermes the Docker socket** so the CEO can call
`docker exec prod-openclaw openclaw message send` itself. Rejected for the
same reason, one step further out: that would be a *second* container with
host root, and unlike OpenClaw it processes tickets authored in a web UI.

Three other routes were measured and do not exist:

- Hermes has no Docker CLI and no socket (verified in the container).
- OpenClaw's gateway has no HTTP send endpoint — four plausible paths, four 404s.
- ntfy sits on `apps`; Hermes is on `agent` only and cannot resolve it.

## Decision

**A dedicated one-way courier: `notify`.**

```
CEO agent → POST prod-notify:8099/notify → docker exec openclaw → WhatsApp
```

It holds the Docker socket so that Hermes does not have to. That is the
entire reason it exists as a container rather than as a function.

This is the same argument that already justifies `cliproxy-heartbeat`, the
only other container trusted with a capability it could misuse: it is safe to
hold a dangerous thing precisely because it runs a fixed script and never
executes model-chosen code. A courier, not an agent.

### What the interface does not allow

- **The recipient is configuration, not a parameter.** `OPERATOR_WHATSAPP`
  comes from the environment and is validated as digits at startup. A caller
  cannot message anyone else.
- **No shell.** `subprocess.run` takes a list. Agent-authored text never
  reaches a shell, so the message body cannot become a command.
- **Text only, ~1500 characters, fixed prefix.** No media, no reply-to, no
  channel selection.
- **One direction.** There is no read path, so nothing a stranger sends on
  WhatsApp can arrive as agent input through this service.

The worst outcome of a prompt-injected CEO is that the operator receives a
silly message.

## Trade-offs

**Gained:** the agent can raise a hand. Work that needs a decision surfaces
within seconds instead of waiting for someone to open the board.

**Given up:** a third container now has the Docker socket, and that is a real
cost, not a rounding error. It is bounded by the interface above rather than
by the socket itself — anything with that socket is root-equivalent, so the
mitigation has to be the narrowness of what the service will do, and it is.

**Not solved:** replies. The operator answering on WhatsApp reaches OpenClaw,
not the CEO. The agent's instructions therefore tell it to ask on the issue as
well, so an answer has somewhere to land.

## Consequences

- `.env` gains `OPERATOR_WHATSAPP` (digits only — the service refuses to
  start otherwise, so a typo fails at boot rather than at the first real
  notification).
- The CEO's `AGENTS.md` documents the endpoint, in the Paperclip volume. That
  file is NOT in this repo; a rebuild of the instructions bundle would drop
  the section.
- Two upstream flag names had to be read off the CLI's own error output:
  `--target` (not `--to`) and `--message` (not `--text`). Both obvious
  guesses are wrong and fail only at send time.

## Follow-up

- [ ] Rate-limit the endpoint. An agent in a retry loop could send dozens of
      messages; nothing currently stops it.
- [ ] Consider whether replies should route back to the CEO, which would mean
      OpenClaw parsing them — a two-way channel is a different ADR.
