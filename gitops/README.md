# gitops/

Desired state for the R2 cluster, reconciled by Argo CD (ADR-0031).

- `bootstrap/root-app.yaml`: applied once; points Argo CD at `apps/`.
- `apps/`: one Argo CD `Application` per component.
- `platform/`: Helm values for Cilium and Argo CD.
- `base/network-policies/`: policies plus the isolation-test fixture (`tests/isolation/run.sh`).

Note: `network-policies` currently points at the isolation fixture. Replace it with
the real per-service policies generated from `catalog/services.yml` (phase 08 follow-up)
before the first sync. Do not sync this app to a real cluster as is.
