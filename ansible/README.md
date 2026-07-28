# ansible/

Host baseline only — the layer beneath Docker. See [ADR-0001](../docs/adr/0001-ansible-for-host-baseline.md).

## Scope boundary

| Ansible owns | Compose owns |
|---|---|
| users, SSH, sudo | containers |
| UFW, fail2ban | images, volumes |
| base packages, swap | application config |
| Docker *installation* | Docker *workloads* |

Resist adding roles beyond these four. Anything application-shaped belongs in
`compose/`, driven by `services.yml`.

## Usage

```bash
make harden-check   # dry run with diff, changes nothing
make harden         # apply
```

## Roles

| Role | Owns |
|---|---|
| `common` | hostname, timezone, base packages, swap |
| `users` | `deploy` user, SSH keys, sudo |
| `security` | sshd config, UFW, fail2ban, unattended-upgrades |
| `docker` | Docker CE, Compose plugin, daemon config, log rotation |

Order matters: `users` must run before `security`, or the playbook disables
root login before a replacement user exists.

## Idempotency

Every role must be idempotent. A second `make harden` immediately after the
first must report `changed=0`. If it does not, a task is written imperatively
and needs fixing — otherwise the repo stops describing the server accurately.

## Current state

Roles are placeholders. Implemented in M1.
