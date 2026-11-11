# Phase 9: Policies with Kyverno

**Goal:** the cluster itself enforces the rules: in the `dkm` namespace, a pod is rejected unless its image
was **signed by your CI workflow on `remodelled`**, is pinned by digest, and the pod declares resource requests and
limits. Pod Security Admission blocks privileged or root containers.

**Time:** 1–2 hours · **Cost:** $0

---

## 9.1 Two layers

| Layer | Built into | Enforces |
|---|---|---|
| **Pod Security Admission** (`restricted` level) | Kubernetes itself | No root, no privilege escalation, no host access, dropped capabilities, seccomp |
| **Kyverno** | an admission webhook | Image signature from your workflow, digest-pinned images, requests and limits |

Your chart already meets all of these (Phase 7's `securityContext`), which is the point: the policies stop
anything that **doesn't** come through the pipeline.

---

## 9.2 Pod Security Admission on the `dkm` namespace

Argo CD creates the namespace, so it sets the labels too. In `gitops/apps/dkmwebapp.yaml`, extend `syncPolicy`:

```yaml
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
    managedNamespaceMetadata:
      labels:
        pod-security.kubernetes.io/enforce: restricted
        pod-security.kubernetes.io/warn: restricted
```

---

## 9.3 Install Kyverno

```bash
helm repo add kyverno https://kyverno.github.io/kyverno && helm repo update
helm search repo kyverno/kyverno          # → ‹kyverno chart›
```

`gitops/platform/kyverno.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://kyverno.github.io/kyverno
    chart: kyverno
    targetRevision: ‹kyverno chart›
    helm:
      valuesObject:
        admissionController:
          replicas: 1                      # production: 3, for availability
          serviceAccount:
            name: kyverno-admission-controller   # matches the Pod Identity association (ECR read) from Phase 3
        backgroundController: { replicas: 1 }
        cleanupController: { replicas: 1 }
        reportsController: { replicas: 1 }
  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
    retry: { limit: 10, backoff: { duration: 15s, factor: 2, maxDuration: 5m } }
```

---

## 9.4 The policies: `gitops/platform-config/kyverno-policies/`

Each policy applies **only to the `dkm` namespace**, so a mistake can't stop system components from starting.

### `verify-image-signatures.yaml`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-dkmwebapp-signature
  annotations:
    policies.kyverno.io/description: >-
      dkmwebapp images must be signed (Cosign keyless) by the CI workflow on remodelled of dkojo/dkmwebapp.
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  rules:
    - name: signed-by-ci-on-remodelled
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [dkm]
      verifyImages:
        - imageReferences:
            - "*.dkr.ecr.us-east-1.amazonaws.com/dkmwebapp*"
          imageRegistryCredentials:
            providers: [amazon]            # uses Kyverno's Pod Identity role to read signatures from ECR
          mutateDigest: true
          verifyDigest: true
          required: true
          attestors:
            - entries:
                - keyless:
                    issuer: https://token.actions.githubusercontent.com
                    subject: https://github.com/dkojo/dkmwebapp/.github/workflows/ci.yml@refs/heads/remodelled
                    rekor:
                      url: https://rekor.sigstore.dev
```

> Newer Kyverno versions also offer an `ImageValidatingPolicy` kind for the same job. `ClusterPolicy` with
> `verifyImages` works across all recent versions, which is why it's used here.

### `restrict-images.yaml`: an allow-list, not just a digest rule

The signature policy only looks at `dkmwebapp` images. Without this one, any *other* image (say a public one,
pinned by digest, with limits) could still run in `dkm`. So the namespace allows exactly one kind of image:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-images
spec:
  validationFailureAction: Enforce
  rules:
    - name: only-digest-pinned-dkmwebapp-from-ecr
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [dkm]
      validate:
        message: "The dkm namespace only runs dkmwebapp images from this account's ECR, pinned by digest (…/dkmwebapp@sha256:…)."
        pattern:
          spec:
            containers:
              - image: "*.dkr.ecr.us-east-1.amazonaws.com/dkmwebapp@sha256:*"
            =(initContainers):
              - image: "*.dkr.ecr.us-east-1.amazonaws.com/dkmwebapp@sha256:*"
```

### `require-resources.yaml`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-requests-and-limits
spec:
  validationFailureAction: Enforce
  rules:
    - name: cpu-memory-requests-memory-limit
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [dkm]
      validate:
        message: "Containers need cpu and memory requests, and a memory limit, so Karpenter can size nodes."
        pattern:
          spec:
            containers:
              - resources:
                  requests: { cpu: "?*", memory: "?*" }
                  limits: { memory: "?*" }
```

`gitops/platform/kyverno-policies.yaml`: the same shape as `karpenter-nodes`, pointing at
`gitops/platform-config/kyverno-policies`, with `SkipDryRunOnMissingResource=true` (the CRDs come with Kyverno).

```bash
git add gitops
git commit -m "Enforce signed, digest-pinned, resource-bounded pods with Kyverno and PSA"
git push
```

---

## ✅ Phase 9 checkpoint

```bash
kubectl get clusterpolicy
# NAME                          ADMISSION   BACKGROUND   READY
# require-requests-and-limits   true        true         True
# restrict-images               true        true         True
# verify-dkmwebapp-signature     true        true         True

kubectl get ns dkm --show-labels | tr ',' '\n' | grep pod-security    # enforce=restricted
```

**Your real pods still pass.** Restart them so they go through admission again:

```bash
kubectl -n dkm rollout restart deployment dkmwebapp
kubectl -n dkm rollout status deployment dkmwebapp      # successfully rolled out
```

**Everything else is refused.** Each of these must fail with a clear message:

```bash
# 1. Someone else's image (here a public one)
kubectl -n dkm run test1 --image=public.ecr.aws/docker/library/nginx:1.27 --dry-run=server
# → denied by restrict-images: "The dkm namespace only runs dkmwebapp images from this account's ECR…"
#   (Pod Security Admission also reports it would run as root)

# 2. Your own repository, but a tag instead of a digest
kubectl -n dkm run test2 --image="$(terraform -chdir=infra/foundation output -raw ecr_repository_url):latest" --dry-run=server
# → denied by restrict-images (not pinned by digest)

# 3. Your own repository, but an image CI never signed (push one by hand to prove it)
REPO=$(terraform -chdir=infra/foundation output -raw ecr_repository_url)
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO%%/*}"
docker pull busybox:1.37 && docker tag busybox:1.37 "$REPO:unsigned-test" && docker push "$REPO:unsigned-test"
DIGEST=$(aws ecr describe-images --repository-name dkmwebapp --image-ids imageTag=unsigned-test --query 'imageDetails[0].imageDigest' --output text)
kubectl -n dkm run test3 --image="$REPO@$DIGEST" \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"test3","image":"'"$REPO@$DIGEST"'","command":["sleep","60"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"memory":"32Mi"}},"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
  --dry-run=server
# → denied by verify-dkmwebapp-signature: no matching signatures
aws ecr batch-delete-image --repository-name dkmwebapp --image-ids imageTag=unsigned-test
```

Test 3 is the important one: **the image is in your own registry, but it wasn't built by your pipeline, so it
can't run.** Screenshot that denial for the portfolio.

### If something goes wrong

| Symptom | Fix |
|---|---|
| Your own dkmwebapp pods are denied: `no matching signatures` | The `subject` must exactly match the signing identity. Run Phase 6's `cosign verify … \| jq '.[0].optional.Subject'` and copy that value. |
| Denied with `failed to fetch` / `unauthorized` for ECR | Kyverno can't read ECR. Check the `kyverno-admission-controller` Pod Identity association and that `imageRegistryCredentials.providers: [amazon]` is set. |
| Every pod creation in `dkm` times out | Kyverno is down and its webhook fails closed. `kubectl -n kyverno get pods`. In an emergency, delete the policies; Argo CD restores them once Kyverno is healthy. |

> ### 🛑 End of session
> Nothing new to clean up. Kyverno creates no AWS resources.

**Next:** [Phase 10: Canary releases](10-canary-releases.md)
