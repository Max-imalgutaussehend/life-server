# ADR-0016: SSH over Cloudflare Access, not Tailscale

- **Status:** Accepted
- **Date:** 2026-07-31
- **Milestone:** M8.5
- **Supersedes:** [ADR-0013](0013-ssh-via-tailscale.md)

## Context

ADR-0013 chose Tailscale as the replacement path for SSH, after which port 22
would close. The end state it wanted — **zero public inbound ports** — is
unchanged and still correct.

The mechanism is not available. The operator's work laptop prohibits installing
Tailscale, and that laptop is one of the two machines administration has to work
from. A remote-access design that cannot be used from the machine the operator
actually sits at is not a design, it is a plan to keep port 22 open forever.

This is a constraint, not a preference. No amount of configuration removes it.

## Decision

**SSH moves to Cloudflare Access instead of Tailscale.** Everything else about
ADR-0013 stands: the end state, the verification discipline, and the console
fallback.

The path becomes:

```
laptop → cloudflared access ssh → Cloudflare edge → tunnel → sshd (127.0.0.1:22)
```

The tunnel is already running for web traffic (ADR-0003), already
outbound-initiated, and already the thing carrying every request to this host.
Adding SSH to it introduces **no new inbound port and no new third party** —
which is the decisive difference from Tailscale, which would have added both.

### Why this works from the work laptop

Nothing needs to be installed system-wide or run as a daemon. `cloudflared` is a
single user-space binary, and browser-based rendering is available as a fallback
that needs no local binary at all. Tailscale, by contrast, installs a network
interface and a background service — precisely what the laptop's policy forbids.

### What does not change

- **Key authentication only.** Access authenticates the *person*; the SSH key
  authenticates the *session*. Two independent factors, neither replacing the
  other. An attacker who defeats Access still faces key-only sshd.
- **The Hetzner Cloud Console (VNC) remains the permanent fallback.** It works
  regardless of SSH, Docker, cloudflared, Cloudflare, or firewall state. Its
  precondition is the root password, which is why that password must exist in a
  password manager even though root SSH login is disabled.

## Alternatives considered

**Keep waiting for a Tailscale-compatible situation.** Rejected: it makes the
end state contingent on a policy the operator does not control, which in
practice means port 22 stays open indefinitely.

**Tailscale on the phone only.** Rejected: administration from a phone is not a
realistic answer for the case where something is broken.

**WireGuard, self-hosted.** Would work and adds no third party beyond what
already exists. Rejected for the same reason as Tailscale: it needs a client and
a network interface on the work laptop.

**Leave port 22 open with fail2ban, permanently.** Honest and defensible — it is
key-only, rate-limited, and has held. Rejected as the *end state* for the reason
ADR-0013 already gave: an open port is exposure to future OpenSSH CVEs, and
removing the port removes the class.

## Trade-offs

**Gained:** zero public inbound ports, reachable from the work laptop, and no
new dependency — the tunnel is already load-bearing for everything else.

**Given up:** Cloudflare becomes a dependency of administrative access, not just
of web traffic. If Cloudflare is down, SSH is down. This concentrates risk in
one provider — mitigated, not eliminated, by the console fallback, which is
independent of Cloudflare entirely.

**Accepted:** a second Access application to maintain, and an operator who must
run `cloudflared access ssh` rather than plain `ssh`. Handled by an
`~/.ssh/config` stanza so the command stays `ssh life-server`.

## Consequences

- A new Access application for `ssh.maxrommel.de`, policy Allow → the operator's
  email, with a short session duration — this one grants shell access, so it
  should not stay authenticated for a month.
- `~/.ssh/config` gains a `ProxyCommand` stanza so muscle memory keeps working.
- UFW's rule for 22/tcp is deleted **only after** the verification below.
- ADR-0013's Phase 2 is void; its Phase 1 hardening remains in force.

## The verification that must pass before port 22 closes

Inherited unchanged from ADR-0013, because the discipline was right:

1. Connect over Access SSH.
2. Disconnect **fully** — no multiplexed session, no `ControlPersist` socket.
3. Reconnect a second time, from a cold start.

Twice, not once. A path that works while a warm connection exists proves nothing
about the path you need when everything is cold.

**Additionally, before closing:** confirm the Hetzner root password is in the
password manager. It is the fallback's only precondition, and a fallback nobody
can use is not a fallback.

## Status of the close, 2026-07-31

**Not done, deliberately.** The configuration is built and committed; the final
`ufw delete` was not run.

The operator was unreachable at the time. Closing the only working access path
requires the console fallback to be real, and the root password could not be
confirmed — it is not in `.env`, not in the repository, and not verifiable from
here. Closing on an unverified fallback is precisely the failure ADR-0013 was
written to prevent, so the port stays open until a human completes the
three-step verification above.

Port 22 remains `ufw limit`, key-only, fail2ban-guarded. That is the same
posture that has held since M1.

## Follow-up

- [ ] Operator: create the `ssh.maxrommel.de` Access application (see
      `docs/milestones/M8.5.md`)
- [ ] Operator: run the three-step verification
- [ ] Operator: confirm the Hetzner root password is in the password manager
- [ ] Then: `sudo ufw delete limit 22/tcp`
