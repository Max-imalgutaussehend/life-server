# ADR-0031: Argo CD owns desired state

- **Status:** Proposed
- **Date:** 2026-10-01
- **Milestone:** R2 phase 09

## Context

R1 deploys with `make deploy`; R2 needs pull-based, drift-correcting delivery (extends ADR-0007).

## Decision

Argo CD app-of-apps in `gitops/`, pointed at `main`. Manual sync until phase 21 wires CI.

## Verification

Changing a manifest in git converges the cluster; a manual `kubectl edit` is reverted.

## Rollback

Delete the Argo CD namespace; workloads keep running because Argo does not own the cluster lifecycle.
