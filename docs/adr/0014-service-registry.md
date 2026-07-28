# ADR-0014: services.yml is the single source of truth for service configuration

- **Status:** Accepted
- **Date:** 2026-07-28
- **Milestone:** M0

## Context

Adding a service to a conventional Docker host means editing the Caddyfile, the
tunnel ingress rules, the Compose file, an env file, the monitoring config and
the documentation. Six edits, six chances to omit one. The omission is usually
silent — a hostname that never routes, a service missing from monitoring — and
surfaces at the worst time.

Over years, this divergence is what makes documentation untrustworthy.

## Decision

**`services.yml` is the only place a service is declared. Everything else is
generated from it by `generator/render.py`.**

```
services.yml
     |
     +--> compose/generated/caddy/Caddyfile
     +--> compose/generated/cloudflared/config.yml
     +--> compose/generated/services.env
     +--> docs/generated/SERVICES.md
```

Adding a service is: one entry, `make generate`, commit.

Three properties make this safe rather than opaque:

1. **Generated output is committed, not gitignored.** The real Caddy config is
   readable in the repo without running anything, `git diff` shows exactly what
   a registry change produced, and the server never needs Python.

2. **Staleness is a commit failure.** `make check` re-renders and compares;
   pre-commit runs it. Hand-edited or out-of-date generated files cannot be
   committed.

3. **Every generated file carries a `DO NOT EDIT` header** naming its source and
   the command to regenerate.

The generator validates the registry: DNS-safe names, duplicate names, port
collisions among enabled services, unknown networks, unknown access values.
A typo fails loudly at generation instead of silently at runtime.

## Alternatives considered

**Hand-edit each file.** No tooling, fully explicit. Rejected: this is the
drift problem the ADR exists to solve.

**Docker labels as the source of truth (Caddy Docker Proxy / Traefik).**
Configuration lives on the container, discovered automatically. Genuinely
attractive, and rejected for one reason: it only generates proxy routes.
Tunnel ingress, docs and monitoring still need a separate source, so the
duplication returns. It also means routing is only inspectable on a running
host, not in Git.

**Generate at container start rather than commit-time.** No committed artifacts
to keep in sync. Rejected: requires Python on the server, makes the effective
config invisible in Git, and turns a rendering error into a startup failure in
production instead of a commit-time failure locally.

## Trade-offs

**Gained:** one edit per service. The documented state and the deployed state
cannot diverge without failing a commit. Adding an env or a service is
mechanical rather than error-prone.

**Given up:** the generator is itself a component to understand — a real cost
against "understandable in three years". Mitigated by keeping it deliberately
boring: plain Python and Jinja2, no framework, no plugins, no dynamic imports,
heavy comments, and committed output that can be read directly.

**Limit, stated plainly:** Cloudflare Access policies cannot be generated. They
live in the Zero Trust dashboard and the tunnel config cannot express them. The
`access:` field records intent and `docs/generated/SERVICES.md` renders it, but
verifying that the dashboard matches is a manual audit step (M3).

## Consequences

- `make generate` after every registry change; `make check` in pre-commit.
- New generated outputs are added by writing a template plus one line in
  `OUTPUTS` in `render.py`.
- Editing a file under `compose/generated/` or `docs/generated/` is always
  wrong; fix the registry or the template.
- The generator needs `pyyaml` and `jinja2` locally. Not on the server.

## Follow-up

- [ ] M2: generate Compose service fragments from the registry
- [ ] M3: audit Cloudflare Access policies against `access:` fields
- [ ] M8: generate Uptime Kuma monitors from the registry
