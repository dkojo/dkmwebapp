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

Argo CD creates the namespace, so it sets the labels too. In `gitops/apps/dkmwebapp.yaml`, add two labels to the
`managedNamespaceMetadata` block from Phase 7:

```yaml
    managedNamespaceMetadata:
      labels:
        elbv2.k8s.aws/pod-readiness-gate-inject: enabled
        pod-security.kubernetes.io/enforce: restricted
        pod-security.kubernetes.io/warn: restricted
```

Check first that nothing running would be rejected. A server-side dry run lists violating pods:

```bash
kubectl label --dry-run=server --overwrite ns dkm pod-security.kubernetes.io/enforce=restricted
# "namespace/dkm labeled (server dry run)" with no warnings = compliant
kubectl label --dry-run=server --overwrite ns observability pod-security.kubernetes.io/enforce=restricted
# warnings: node-exporter and the OTel collector need host access by design, which is why these rules are scoped
# to the app namespace only
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
    targetRevision: 3.10.0                 # Kyverno v1.20.0
    helm:
      valuesObject:
        # The admission controller's service account is kyverno-admission-controller by default, which matches
        # the Pod Identity association from Phase 3 (ECR read-only, to fetch signatures).
        admissionController: { replicas: 1 }     # production: 3, for availability (its webhook fails closed)
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

⚠️ **Kyverno 1.20 no longer enforces the classic `kyverno.io/v1` `ClusterPolicy`.** They install, then report
`READY False: policy is not enforced: legacy kyverno.io policies are no longer supported`. Use the CEL-based
`policies.kyverno.io/v1` types: `ImageValidatingPolicy` for signatures, `ValidatingPolicy` for everything else
(the same CEL that Kubernetes' own `ValidatingAdmissionPolicy` uses). Check what your cluster serves with
`kubectl api-resources --api-group=policies.kyverno.io`.

⚠️ **Cosign v3 stores signatures as Sigstore bundles attached as OCI referrers, not as `sha256-….sig` tags.**
Check yours: `aws ecr describe-images --repository-name dkmwebapp --query 'imageDetails[].artifactMediaType'`
shows `application/vnd.dev.sigstore.bundle.v0.3+json`. A verifier that only looks for `.sig` tags rejects every
genuinely signed image.

Each policy applies **only to the `dkm` namespace**, so a mistake can't stop system components from starting.
All three start with `validationActions: [Audit]` (step 9.5).

### `verify-image-signatures.yaml`

```yaml
# Kyverno 1.20 no longer enforces legacy kyverno.io ClusterPolicies, so these use the CEL-based policies.kyverno.io
# types. ImageValidatingPolicy verifies Cosign v3's Sigstore bundles (attached as OCI referrers); tested before
# enforcing: the CI-signed image was admitted, a hand-pushed unsigned one was denied.
apiVersion: policies.kyverno.io/v1
kind: ImageValidatingPolicy
metadata:
  name: verify-dkmwebapp-signature
spec:
  validationActions: [Audit]               # report first; Deny once the policy report shows the app passing
  failurePolicy: Fail                       # if Kyverno can't verify, the pod doesn't start
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
    namespaceSelector:
      matchLabels: { kubernetes.io/metadata.name: dkm }
  matchImageReferences:
    - glob: "*.dkr.ecr.us-east-1.amazonaws.com/dkmwebapp*"
  credentials:
    providers: [amazon]                     # Kyverno's Pod Identity role (ECR read-only) fetches the signatures
  validationConfigurations:
    mutateDigest: true                      # a tag is resolved to the digest that was verified
    verifyDigest: true
    required: true
  attestors:
    - name: ci
      cosign:
        keyless:
          identities:
            - issuer: https://token.actions.githubusercontent.com
              subject: https://github.com/dkojo/dkmwebapp/.github/workflows/ci.yml@refs/heads/remodelled
        ctlog:
          url: https://rekor.sigstore.dev     # the signature must be in the public transparency log
  validations:
    - expression: >-
        images.containers.map(image, verifyImageSignatures(image, [attestors.ci])).all(e, e > 0)
      message: "dkmwebapp images must be signed (Cosign keyless) by ci.yml on remodelled of dkojo/dkmwebapp"
```

**Test the verifier before relying on it**, in a scratch namespace with `Deny`: the CI-signed image must be
admitted, and an image you push by hand (never signed) must be denied. A policy that admits everything also
passes the first test.

### `restrict-images.yaml`: an allow-list, not just a digest rule

```yaml
# An allow-list, not just a digest rule: the signature policy only looks at dkmwebapp images, so without this any
# other image (a public one, pinned, with limits) could still run in dkm.
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: restrict-images
spec:
  validationActions: [Audit]
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
    namespaceSelector:
      matchLabels: { kubernetes.io/metadata.name: dkm }
  variables:
    - name: allowed
      # CEL raw string (r'…'), so the backslashes reach the regex engine unchanged
      expression: >-
        r'^[0-9]{12}\.dkr\.ecr\.us-east-1\.amazonaws\.com/dkmwebapp@sha256:[a-f0-9]{64}$'
  validations:
    - expression: >-
        object.spec.containers.all(c, c.image.matches(variables.allowed)) &&
        (!has(object.spec.initContainers) || object.spec.initContainers.all(c, c.image.matches(variables.allowed)))
      message: "The dkm namespace only runs dkmwebapp images from this account's ECR, pinned by digest (…/dkmwebapp@sha256:…)."
```

### `require-resources.yaml`

```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: require-requests-and-limits
spec:
  validationActions: [Audit]
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
    namespaceSelector:
      matchLabels: { kubernetes.io/metadata.name: dkm }
  validations:
    - expression: >-
        object.spec.containers.all(c,
          has(c.resources) && has(c.resources.requests) && has(c.resources.limits) &&
          'cpu' in c.resources.requests && 'memory' in c.resources.requests && 'memory' in c.resources.limits)
      message: "Containers need cpu and memory requests, and a memory limit, so Karpenter can size nodes."
```

`gitops/platform/kyverno-policies.yaml`: the same shape as `karpenter-nodes`, pointing at
`gitops/platform-config/kyverno-policies`, with `SkipDryRunOnMissingResource=true` (the CRDs come with Kyverno).

```bash
git add gitops
git commit -m "Add Kyverno and Pod Security Admission, policies in Audit mode first"
git push
```

---

## 9.5 Audit, read the reports, then enforce

A policy that rejects the production app's next rollout is an outage you caused. So: report first.

```bash
kubectl get validatingpolicy,imagevalidatingpolicy        # READY true, ACTIONS [Audit]
kubectl -n dkm rollout restart deploy/dkmwebapp            # new pods go through admission
kubectl -n dkm get policyreport -o json | jq -r '.items[] | select(.scope.kind=="Pod") | .scope.name as $p
  | .results[] | "\($p) \(.policy) \(.result)"' | sort -u
# every line: pass
```

Then change `validationActions: [Audit]` to `[Deny]` in all three files, commit and push.

If Argo CD gets stuck retrying an old sync (for example one that still tries to apply a legacy `ClusterPolicy`,
which Kyverno now refuses), cancel it and refresh:

```bash
kubectl -n argocd patch application kyverno-policies --type json -p '[{"op":"remove","path":"/operation"}]'
kubectl -n argocd annotate application kyverno-policies argocd.argoproj.io/refresh=hard --overwrite
```

---

## ✅ Phase 9 checkpoint

```bash
kubectl get validatingpolicy,imagevalidatingpolicy
# NAME                          READY   ACTIONS
# require-requests-and-limits   true    [Deny]
# restrict-images               true    [Deny]
# verify-dkmwebapp-signature    true    [Deny]
```

Five ways to sneak a pod into `dkm`, all of which must be rejected (`--dry-run=server` runs admission without
creating anything), and one that must work:

| Attempt | Rejected by |
|---|---|
| 1. Someone else's image (`nginx:1.29`) | `restrict-images` |
| 2. Your repository, but a tag instead of a digest | `restrict-images` |
| 3. Your repository, pinned, but never signed by CI (push one by hand) | `verify-dkmwebapp-signature` |
| 4. The real signed image with no resource limits | `require-requests-and-limits` |
| 5. A privileged, root container | Pod Security Admission (`restricted`) |
| 6. **The real app**: `kubectl -n dkm rollout restart deploy/dkmwebapp` | admitted, rolls out |

For 3: `docker tag dkmwebapp:scan "$REPO:unsigned-test" && docker push "$REPO:unsigned-test"`, then use its digest
from `aws ecr describe-images --repository-name dkmwebapp --image-ids imageTag=unsigned-test`. Delete it
afterwards with `aws ecr batch-delete-image --repository-name dkmwebapp --image-ids imageTag=unsigned-test`.

### If something goes wrong

| Symptom | Fix |
|---|---|
| Your own dkmwebapp pods are denied by `verify-dkmwebapp-signature` | The `subject` must exactly match the signing identity, `https://github.com/dkojo/dkmwebapp/.github/workflows/ci.yml@refs/heads/remodelled`. Check with Phase 6's `cosign verify --certificate-identity …` (exact identity, `MSYS_NO_PATHCONV=1` in Git Bash). |
| Policies show `READY False: legacy kyverno.io policies are no longer supported` | You're using `kyverno.io/v1` `ClusterPolicy` on Kyverno 1.20+. Use the `policies.kyverno.io/v1` types in 9.4. |
| Denied with `failed to fetch` / `unauthorized` for ECR | Kyverno can't read ECR. Check the `kyverno-admission-controller` Pod Identity association and that `credentials.providers: [amazon]` is set. |
| Every pod creation in `dkm` times out | Kyverno is down and its webhook fails closed. `kubectl -n kyverno get pods`. In an emergency, delete the policies; Argo CD restores them once Kyverno is healthy. |

> ### 🛑 End of session
> Nothing new to clean up. Kyverno creates no AWS resources.

**Next:** [Phase 10: Canary releases](10-canary-releases.md)
