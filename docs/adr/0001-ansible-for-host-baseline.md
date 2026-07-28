# ADR-0001: Ansible for the host baseline, Compose for everything above it

- **Status:** Accepted
- **Date:** 2026-07-28
- **Milestone:** M0

## Context

The server must be reproducible from Git. The single most likely reason to
rebuild a long-lived personal server is host-level drift that cannot be
reconstructed — a sysctl set during troubleshooting, a package installed once
and forgotten, an sshd option nobody documented.

Three options were considered for how host configuration is applied.

## Decision

**Ansible manages the host baseline. Docker Compose manages everything above
it. The boundary is strict.**

Ansible's scope is deliberately capped at four roles:

| Role | Owns |
|---|---|
| `common` | hostname, timezone, base packages, swap |
| `users` | the `deploy` user, SSH keys, sudo |
| `security` | sshd config, UFW, fail2ban, unattended-upgrades |
| `docker` | Docker CE, Compose plugin, daemon config, log rotation |

Ansible does **not** manage containers, images, volumes or application config.
That is Compose's job, driven by `services.yml`.

## Alternatives considered

**Manual commands with prose documentation.** Fastest to start. Rejected: the
host baseline is exactly the layer that cannot be reconstructed from prose two
years later, and it is the layer where a mistake locks you out.

**Idempotent shell scripts in Git.** Cheaper than Ansible, no dependency.
Rejected: you end up hand-writing idempotency (does this user exist? is this
line already in sshd_config?) — that is reimplementing Ansible, badly. It
degrades into unmaintainable branching as cases accumulate.

**Ansible with Galaxy collections (geerlingguy.docker etc.).** Less code to
write. Rejected for this repo: pulls in external dependencies whose upgrade
cadence you do not control, for maybe 40 lines of saved work. Contradicts the
"understandable in three years" goal.

## Trade-offs

**Gained:** rebuilding the host is one command. A second server, or a move to
different hardware, reuses the same playbook. Every host change is a reviewable
diff.

**Given up:** roughly 45 minutes of upfront work before anything visible runs,
plus a learning curve if Ansible is unfamiliar. `ansible` must be installed
locally (it is not needed on the server — Ansible is agentless).

**Risk accepted:** Ansible's scope can creep. Mitigated by the strict role list
above; anything application-shaped belongs in Compose.

## Consequences

- `brew install ansible` is a prerequisite for M1.
- `make harden` and `make harden-check` are the only ways host config changes.
- A host change made by hand over SSH is a bug: it will be silently reverted on
  the next playbook run, or worse, will not be, and the repo becomes a lie.
- Every role must be idempotent — `make harden` twice must report no changes
  the second time. This is verified in M1.

## Follow-up

- [ ] M1: implement the four roles
- [ ] M1: verify idempotency (second run reports `changed=0`)
- [ ] M7: run `make harden-check` in CI to detect server drift
