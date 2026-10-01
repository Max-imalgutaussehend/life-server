# ADR-0032: Secrets with SOPS and age

- **Status:** Proposed
- **Date:** 2026-10-01
- **Milestone:** R2 phase 10

## Context

R1 uses `.env` then SOPS (ADR-0006). Kubernetes needs the same without plaintext in git.

## Decision

SOPS-encrypted manifests, age recipient in `.sops.yaml`, decrypted in-cluster by the Argo CD ksops plugin. The private key exists in two places outside git (operator machine, offline backup).

## Verification

A secret committed to git is unreadable without the key; a pod receives the decrypted value.

## Rollback

Rotate the age key and re-encrypt; plaintext never enters git, so nothing needs purging.
