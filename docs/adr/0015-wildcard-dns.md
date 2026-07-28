# ADR-0015: Wildcard DNS — adding a service never touches DNS

- **Status:** Accepted
- **Date:** 2026-07-28
- **Milestone:** M0 (constraint), M3 (verification)

## Context

Adding a service to a conventional setup means creating a DNS record, waiting
for propagation, and remembering to remove it when the service is retired.
That is a second registry to keep in sync with the first, maintained in a web
dashboard rather than in Git — and it is a step that is easy to forget and slow
to debug when forgotten (the symptom is an unhelpful NXDOMAIN).

## Decision

**A single wildcard record covers every service, for both environments.
Adding a service never touches DNS.**

```
*.maxrommel.de       -> Cloudflare tunnel   (proxied)
*.dev.maxrommel.de   -> Cloudflare tunnel   (proxied)
```

Adding a public service therefore requires exactly three things, none of which
is DNS:

1. an entry in `services.yml`
2. a generated reverse-proxy route (produced by `make generate`)
3. a generated tunnel ingress rule (produced by `make generate`)

Steps 2 and 3 are the same command, so in practice it is one file plus
`make generate`.

**Corollary — no hostname is ever written literally.** Every hostname is
derived at runtime:

```
<service name> + <env infix> + <domain>

prod:  ENV_PREFIX=""      ->  n8n.maxrommel.de
dev:   ENV_PREFIX=".dev"  ->  n8n.dev.maxrommel.de
```

`DOMAIN` and `ENV` live in `.env`; `ENV_PREFIX` is derived from `ENV`. A
literal hostname anywhere in this repository is a bug: it breaks the dev/prod
split (ADR-0010) and it means the domain cannot be changed in one place.

## Alternatives considered

**One CNAME per service.** Explicit — DNS shows exactly what exists. Rejected:
a second registry, maintained outside Git, that must be kept in sync with
`services.yml`. It also makes the dev stack twice the work.

**`cloudflared` managing DNS via API.** The tunnel can create records itself
(`cloudflared tunnel route dns`). Rejected: requires an API token with DNS edit
rights stored on the server — a credential that can rewrite the whole zone, in
exchange for automating something a wildcard makes unnecessary.

**A wildcard for prod, explicit records for dev.** Rejected as inconsistent for
no benefit; two rules to remember instead of one.

## Trade-offs

**Gained:** a new service is one file plus one command. No propagation wait, no
dashboard step, no forgotten cleanup. The dev environment costs nothing extra
in DNS.

**Given up — worth stating plainly:** a wildcard resolves *every* subdomain,
including ones that do not exist. `typo.maxrommel.de` resolves and reaches the
tunnel rather than failing at DNS. This is why the tunnel config ends with an
explicit `http_status:404` catch-all: unmatched hostnames are refused at the
tunnel, not silently routed somewhere.

It also means subdomain enumeration reveals nothing, since everything resolves
— a small privacy benefit, not a security control.

**Not a security boundary.** DNS resolving is not access. Cloudflare Access
(ADR-0003) is what gates who reaches a service.

## Consequences

- The wildcard records must be **proxied** (orange cloud). Grey-cloud DNS-only
  would expose the origin IP and bypass the tunnel entirely.
- The catch-all `- service: http_status:404` must remain the last tunnel
  ingress rule. The generator emits it unconditionally.
- Certificate coverage comes from Cloudflare's edge certificate, which covers
  one wildcard level. `*.maxrommel.de` covers `n8n.maxrommel.de`;
  `*.dev.maxrommel.de` is a separate record for that reason.
- A grep for the literal domain outside `.env` and `env.example` should return
  nothing. Worth checking when adding services.

## Follow-up

- [ ] M3: create both wildcard records, proxied
- [ ] M3: verify an unregistered hostname returns 404 from the tunnel, not a
      connection error or a wrong service
- [ ] M3: confirm the edge certificate covers both wildcard levels
