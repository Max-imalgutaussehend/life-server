#!/usr/bin/env bash
# Proves the ADR-0028 security idea: apps may reach data, agents may not.
# Needs docker, kind, kubectl, helm. Creates and deletes cluster aevia-iso.
set -euo pipefail
cd "$(dirname "$0")/../.."
CL=aevia-iso
trap 'kind delete cluster --name $CL >/dev/null 2>&1 || true' EXIT
kind create cluster --name $CL --config tests/isolation/kind.yaml --wait 0s
helm repo add cilium https://helm.cilium.io >/dev/null
helm upgrade --install cilium cilium/cilium --namespace kube-system \
  -f gitops/platform/cilium/values.yaml \
  --set k8sServiceHost=$CL-control-plane --set k8sServicePort=6443 --wait --timeout 8m
kubectl apply -f gitops/base/network-policies/isolation-test-fixture.yaml
for ns in data apps agents; do kubectl -n $ns wait --for=condition=Ready pod --all --timeout=180s; done
try() { kubectl -n "$1" exec client -- curl -s -m 5 -o /dev/null -w '%{http_code}' http://postgres.data.svc.cluster.local 2>/dev/null || true; }
a=$(try apps); g=$(try agents)
echo "apps -> data:   ${a:-none} (expect 200)"
echo "agents -> data: ${g:-none} (expect refused)"
[[ $a == 200 ]] || { echo "FAIL: apps cannot reach data"; exit 1; }
[[ $g != 200 ]] || { echo "FAIL: agents reached data"; exit 1; }
echo "PASS"
