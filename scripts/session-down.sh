#!/usr/bin/env bash
# End of a work session: remove what Kubernetes created in AWS, then destroy the platform stack, then check.
set -euo pipefail
cd "$(dirname "$0")/.."
$(scripts/tf.sh platform output -raw configure_kubectl) >/dev/null   # honours ENV, like session-up.sh

wait_until_empty() {   # wait_until_empty <description> <command that lists remaining things>
  echo "   waiting for $1…"
  timeout 900 bash -c "until [ -z \"\$($2 2>/dev/null)\" ]; do sleep 10; done" \
    || { echo "!! timed out waiting for $1 — check by hand before destroying"; exit 1; }
}

echo "1/6 Stop the root apps from recreating their children"
kubectl -n argocd delete application apps platform --ignore-not-found

echo "2/6 Delete the app and load generator (their Ingress owns the ALB and the DNS record)"
kubectl -n argocd delete application dkmwebapp loadgen --ignore-not-found
wait_until_empty "the ALB-backed Ingress to go" "kubectl get ingress -A -o name"

echo "3/6 Delete stateful add-ons and their EBS volumes"
kubectl -n argocd delete application kube-prometheus-stack loki tempo otel-collector --ignore-not-found
kubectl delete namespace observability --ignore-not-found
wait_until_empty "PersistentVolumes to be released" "kubectl get pv -o name"

echo "4/6 Let Karpenter terminate the nodes it launched"
kubectl -n argocd delete application karpenter-nodes --ignore-not-found
wait_until_empty "Karpenter nodes to terminate" "kubectl get nodeclaims -o name"

echo "5/6 Destroy the platform stack"
scripts/tf.sh platform destroy -auto-approve

echo "6/6 Check for leftovers"
scripts/check-leftovers.sh
