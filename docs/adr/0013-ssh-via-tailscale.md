# ADR-0013: SSH stays open until Tailscale is proven, then closes

- **Status:** Accepted
- **Date:** 2026-07-28
- **Milestone:** M0 (decision), M1 (hardening), M8.5 (Tailscale, close port 22)

## Context

The target state is that port 22 is not reachable from the internet: SSH arrives
over Tailscale, web traffic over Cloudflare Tunnel, and the server accepts no
inbound connection from the public internet at all.

The question is not whether, but when. Closing SSH before the replacement path
is proven creates a state where the only way in is a service that runs in a
container, depends on a third party, and can fail.

## Decision

**Phase 1 (M1 → M8.5): port 22 open, heavily restricted.**

- key authentication only, passwords disabled
- root login disabled; access via the `deploy` user
- `ufw limit 22/tcp` — rate limiting, not plain `allow`
- fail2ban on sshd

**Phase 2 (M8.5): Tailscale installed and verified, then port 22 closed.**

The close only happens after: connect over Tailscale, disconnect fully,
reconnect a second time. Verified twice, not assumed once — the same discipline
as the M1 lockout rehearsal.

**Permanent fallback, independent of all of the above:** the Hetzner Cloud
Console (VNC) works regardless of SSH, Docker, Tailscale or firewall state. Its
requirement is the root password, which is why the root password must exist in
a password manager even though root SSH login is disabled.

## Alternatives considered

**Close port 22 immediately in M1, install Tailscale first.** Reaches the target
state sooner. Rejected: it makes a container-dependent, third-party-dependent
service the sole access path before the rest of the system is stable.

**Leave SSH open permanently with fail2ban.** Common and defensible.
Rejected as the end state: key-only SSH is strong, but an open port is still an
open port, subject to future OpenSSH CVEs. Removing it removes a class of risk.

**Change SSH to a non-standard port.** Reduces log noise from scanners.
Rejected: not a security measure, and it complicates tooling and documentation
for a cosmetic gain.

## Trade-offs

**Gained (after M8.5):** zero public inbound ports. Nothing on the internet can
initiate a connection to the server.

**Given up:** dependency on Tailscale for administrative access. If Tailscale's
coordination server is unreachable and an existing connection is not
established, the console is the only way in.

**Deliberate delay accepted:** roughly eight milestones with port 22 open,
mitigated by key-only auth, rate limiting and fail2ban.

## Consequences

- M1 uses `ufw limit` rather than `allow` for 22 — rate limiting from the start.
- The root password must be in a password manager before M1 disables root SSH.
  This is the console fallback and it is not optional.
- M8.5 must verify Tailscale connectivity twice before closing the port.
- Pull-based deployment (ADR-0007) is what makes closing port 22 possible
  without breaking CI — a push-based deploy would need Tailscale on the runner.

## Follow-up

- [x] M1: `ufw limit 22/tcp`, key-only, root login disabled
- [ ] M1: confirm the root password is stored before hardening
- [ ] ~~M8.5: install Tailscale, verify connect/disconnect/reconnect~~ — **blocked**
- [ ] M8.5: close port 22, then verify console access still works

## Constraint discovered 2026-07-30: Tailscale is not available

The operator's work laptop prohibits Tailscale by policy. **Phase 2 as written
above cannot be executed**, so this ADR's mechanism — not its goal — is dead.

What is unaffected: Phase 1 is in place and verified (key-only, root disabled,
`ufw limit`, fail2ban — 1056 failed attempts and 95 bans absorbed so far), and
the Hetzner console fallback is untouched.

What needs a decision at M8.5: the replacement path. The leading candidate is
**Cloudflare Tunnel's SSH support behind Access** — no client software, no VPN,
browser-authenticated against the operator's identity, and it reuses the tunnel
already running for web traffic (ADR-0003). It reaches the same end state of
zero public inbound ports, and is *less* exposed than today's open port 22,
trading that for a Cloudflare dependency on the admin path.

This ADR is **not amended to adopt that** — the choice is unconfirmed, and a
superseding ADR belongs to M8.5 where the mechanism is actually built and
verified. Recorded here so the constraint is not rediscovered later.

Note that a server-side tailnet would still be viable if administration ever
happens from a personal machine; the blocker is client-side policy, not the
server.
