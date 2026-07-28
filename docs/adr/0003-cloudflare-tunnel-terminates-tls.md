# ADR-0003: Cloudflare Tunnel terminates TLS; Caddy never binds a host port

- **Status:** Accepted
- **Date:** 2026-07-28
- **Milestone:** M0 (decision), M3 (implementation)

## Context

Both Caddy and Cloudflare Tunnel can terminate HTTPS. Running both without
deciding which one owns TLS produces double termination, a confusing request
path, and — the real danger — a Caddy that binds `0.0.0.0:443` "just in case",
silently reintroducing the public attack surface the tunnel was meant to remove.

## Decision

**Cloudflare terminates TLS at its edge. `cloudflared` reaches Caddy over the
internal Docker network. Caddy publishes no host ports. UFW has no rule for
80 or 443.**

Request path:

```
client --TLS--> Cloudflare edge --encrypted tunnel--> cloudflared
                                                        |
                                             docker network 'edge'
                                                        v
                                                   caddy:80 --> app
```

Caddy runs with `auto_https off` and no `ports:` directive in Compose.

**Caddy is kept** even though the tunnel could address containers directly.
It owns routing, headers and path rules, and it is the seam that makes future
non-Cloudflare ingress (Tailscale, LAN) a config change rather than a rebuild.

## Alternatives considered

**Cloudflared → containers directly, no Caddy.** One less hop. Rejected:
routing logic would live in the tunnel config only, and adding any local or
Tailscale-based access later would require introducing a proxy at that point
anyway.

**Caddy terminates TLS with Let's Encrypt, ports 80/443 open.** The
conventional setup. Rejected: requires two open inbound ports, exposes the
origin IP, and forfeits Cloudflare's WAF, DDoS absorption and Access layer.

**Cloudflare Tunnel with `noTLSVerify` to an HTTPS Caddy.** Encrypts the final
hop. Rejected as security theatre: that hop is a Docker bridge network on a
single host, already isolated, and the added certificate management has no
corresponding threat.

## Trade-offs

**Gained:** exactly one inbound port on the whole server (22, and that closes
in M8.5 per ADR-0013). Origin IP is not published. Cloudflare Access can gate
every hostname before traffic reaches the box.

**Given up:** Cloudflare sees plaintext traffic — they are trusted by
construction. An outage at Cloudflare means every service is unreachable from
outside; SSH still works. Some WebSocket and streaming workloads need tunnel
tuning.

**Risk accepted:** dependence on a single vendor for all external reachability.
Mitigated by keeping Caddy: swapping ingress is a config change, not a rewrite.

## Consequences

- No Compose service may declare `ports:` for anything web-facing.
- `compose/generated/caddy/Caddyfile` and `cloudflared/config.yml` are both
  generated from `services.yml` (ADR-0014); routing is never edited by hand.
- Every `access: private` service must also have a Cloudflare Access policy.
  Access policies live in the Zero Trust dashboard and cannot be expressed in
  the tunnel config — so this is a **manual step that must be audited** against
  `docs/generated/SERVICES.md` whenever a service is added.

## Follow-up

- [ ] M3: create tunnel, set `CLOUDFLARE_TUNNEL_TOKEN` in .env
- [ ] M3: confirm `ss -tulpn` on the host shows no listener on 80/443
- [ ] M3: create an Access policy for every `access: private` service
- [ ] M3: document the Access audit procedure in `docs/milestones/M3.md`
