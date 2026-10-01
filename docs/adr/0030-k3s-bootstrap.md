# ADR-0030: Bootstrap k3s with Cilium as CNI

- **Status:** Proposed
- **Date:** 2026-10-01
- **Milestone:** R2 phase 07-08

## Context

Single-node k3s on the R2 VPS; the default flannel CNI cannot enforce the isolation required by ADR-0028.

## Decision

Install k3s with `--flannel-backend=none --disable-network-policy --disable=traefik --disable=servicelb`, then Cilium. Every namespace gets a default-deny policy; allow-rules derive from `needs` in `catalog/services.yml`.

## Verification

A test pod in the `agents` namespace cannot reach Postgres/Redis; the same test is automated in CI against a kind cluster.

## Rollback

Uninstall k3s (`k3s-uninstall.sh`) and rebuild the node from tofu; no data exists yet at this phase.
