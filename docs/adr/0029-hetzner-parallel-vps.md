# ADR-0029: Provision the parallel R2 VPS with OpenTofu

- **Status:** Proposed
- **Date:** 2026-10-01
- **Milestone:** R2 phase 06

## Context

R2 is built on a new Hetzner VPS next to R1 (ADR-0028). The `hetzner` module creates network, firewall, server and data volume.

## Decision

Apply `environments/production` after the state bootstrap ([runbook](../runbooks/tofu-bootstrap.md)). One node first (`role=control`); the agent node is added in phase 23. Firewall exposes no 80/443; SSH/6443 only for `ssh_allowed_cidrs`. Volumes have `prevent_destroy`.

## Verification

`tofu plan` shows the expected resources; after apply the node answers SSH from an allowed CIDR and from nowhere else.

## Rollback

`tofu destroy` of the environment; volumes need `prevent_destroy` removed deliberately. R1 is unaffected.
