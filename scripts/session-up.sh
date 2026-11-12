#!/usr/bin/env bash
# Start of a work session: create the platform stack, then hand the cluster to Argo CD.
#   scripts/session-up.sh              # prod
#   ENV=dev scripts/session-up.sh      # another environment (see infra/platform/envs/)
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/tf.sh platform apply -auto-approve
$(scripts/tf.sh platform output -raw configure_kubectl)

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm upgrade --install argocd argo/argo-cd --namespace argocd --create-namespace \
  --version 10.18.0 -f gitops/bootstrap/argocd-values.yaml --wait --timeout 10m

# Only the Kubernetes objects: argocd-values.yaml in the same folder is a Helm values file, not a manifest.
kubectl apply -f gitops/bootstrap/karpenter-oci-repo.yaml -f gitops/bootstrap/root.yaml -f gitops/bootstrap/apps-root.yaml
echo "Argo CD is syncing. Watch with: kubectl -n argocd get applications -w"
