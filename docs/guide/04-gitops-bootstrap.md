# Phase 4: GitOps bootstrap and add-ons

**Goal:** Argo CD running in the cluster and installing every add-on from your Git repo: the AWS Load Balancer
Controller, ExternalDNS, Karpenter (with a spot-friendly NodePool) and External Secrets. After this phase, nothing
inside the cluster is installed by hand except Argo CD itself.

**Time:** about 2 hours · **💰 Cost while running:** same as Phase 3 (~$0.25/h), plus any Karpenter node it launches

---

## 4.1 How the pieces fit

```
you ──helm install──▶ Argo CD
you ──kubectl apply──▶ gitops/bootstrap/root.yaml   (an Application that watches gitops/platform/)
                         │
                         ▼
        gitops/platform/*.yaml  — one Argo CD Application per add-on
          ├─ aws-load-balancer-controller   (Helm chart)
          ├─ external-dns                   (Helm chart)
          ├─ external-secrets               (Helm chart)
          ├─ karpenter                      (Helm chart, OCI)
          └─ karpenter-nodes                (your NodePool + EC2NodeClass from gitops/platform-config/)
```

This "app of apps" pattern means adding an add-on is a Git commit: drop a new Application file into
`gitops/platform/` and Argo CD installs it.

---

## 4.2 Look up and pin the chart versions

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add eks https://aws.github.io/eks-charts
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm search repo argo/argo-cd                          # CHART VERSION column → ‹argocd chart›
helm search repo eks/aws-load-balancer-controller      # → ‹lbc chart›
helm search repo external-dns/external-dns             # → ‹external-dns chart›
helm search repo external-secrets/external-secrets     # → ‹eso chart›
# Karpenter (OCI registry): the latest release tag without the "v", e.g. 1.8.2
gh api repos/aws/karpenter-provider-aws/releases/latest --jq .tag_name   # → ‹karpenter chart›
```

Write these five versions down. Every `‹… chart›` placeholder below is one of them.

---

## 4.3 Install Argo CD

`gitops/bootstrap/argocd-values.yaml`:

```yaml
global:
  nodeSelector:
    karpenter.sh/controller: "true"     # keep Argo CD on the fixed system nodes

configs:
  params:
    server.insecure: true               # you reach the UI through kubectl port-forward, not the internet
  cm:
    timeout.reconciliation: 60s         # check Git every minute

dex:
  enabled: false                        # no SSO needed for a personal cluster

notifications:
  enabled: true                         # Slack notifications are configured in Phase 6
```

```bash
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version ‹argocd chart› \
  -f gitops/bootstrap/argocd-values.yaml --wait

kubectl -n argocd get pods      # all Running
```

### Open the UI

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8081:80
# open http://localhost:8081   user: admin   password: the line printed above
```

Keep that terminal open while you use the UI.

---

## 4.4 The root Application

`gitops/bootstrap/root.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/dkojo/dkmwebapp.git
    targetRevision: remodelled
    path: gitops/platform
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Karpenter's chart is in an OCI registry, which Argo CD has to be told about.
`gitops/bootstrap/karpenter-oci-repo.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: karpenter-oci
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  name: karpenter
  type: helm
  url: public.ecr.aws/karpenter
  enableOCI: "true"
```

(This secret has no credentials; it only registers a public registry.)

---

## 4.5 The add-on Applications: `gitops/platform/`

Every Application here uses the same `syncPolicy`. The `finalizers` line matters for teardown: deleting the
Application deletes what it created, including AWS load balancers.

### `aws-load-balancer-controller.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: aws-load-balancer-controller
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://aws.github.io/eks-charts
    chart: aws-load-balancer-controller
    targetRevision: ‹lbc chart›
    helm:
      valuesObject:
        clusterName: dkm
        region: us-east-1
        # Find the VPC by its Name tag. The nodes' IMDS hop limit is 1 (pods can't read instance metadata),
        # and a tag lookup keeps working when the VPC is recreated each session, unlike a hard-coded vpcId.
        vpcTags:
          Name: dkm
        replicaCount: 1
        serviceAccount:
          name: aws-load-balancer-controller   # matches the Pod Identity association from Phase 3
        nodeSelector:
          karpenter.sh/controller: "true"
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
    retry: { limit: 10, backoff: { duration: 15s, factor: 2, maxDuration: 5m } }
```

### `external-dns.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: external-dns
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://kubernetes-sigs.github.io/external-dns
    chart: external-dns
    targetRevision: ‹external-dns chart›
    helm:
      valuesObject:
        provider:
          name: aws
        env:
          - name: AWS_DEFAULT_REGION
            value: us-east-1
        domainFilters: [danielkojomegbenu.com]
        sources: [ingress]
        policy: sync              # also deletes records when an Ingress is removed
        registry: txt
        txtOwnerId: dkm          # only touches records it created; your portfolio's records are safe
        serviceAccount:
          name: external-dns
  destination:
    server: https://kubernetes.default.svc
    namespace: external-dns
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
    retry: { limit: 10, backoff: { duration: 15s, factor: 2, maxDuration: 5m } }
```

⚠️ `txtOwnerId` is what keeps ExternalDNS away from your portfolio's DNS records. Don't remove it.

### `external-secrets.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: external-secrets
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://charts.external-secrets.io
    chart: external-secrets
    targetRevision: ‹eso chart›
    helm:
      valuesObject:
        installCRDs: true
        serviceAccount:
          name: external-secrets
  destination:
    server: https://kubernetes.default.svc
    namespace: external-secrets
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
    retry: { limit: 10, backoff: { duration: 15s, factor: 2, maxDuration: 5m } }
```

### `karpenter.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: karpenter
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: public.ecr.aws/karpenter
    chart: karpenter
    targetRevision: ‹karpenter chart›
    helm:
      valuesObject:
        settings:
          clusterName: dkm
          interruptionQueue: Karpenter-dkm   # check: scripts/tf.sh platform output karpenter_queue_name
        serviceAccount:
          name: karpenter
        replicas: 1
        nodeSelector:
          karpenter.sh/controller: "true"     # Karpenter must never run on a node it manages
        controller:
          env:
            - name: AWS_REGION   # don't rely on instance metadata (hop limit 1) to discover the region
              value: us-east-1
          resources:
            requests: { cpu: 250m, memory: 512Mi }
            limits: { memory: 512Mi }
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
    retry: { limit: 10, backoff: { duration: 15s, factor: 2, maxDuration: 5m } }
```

### `karpenter-nodes.yaml`: your node rules, from your repo

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: karpenter-nodes
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://github.com/dkojo/dkmwebapp.git
    targetRevision: remodelled
    path: gitops/platform-config/karpenter
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true, SkipDryRunOnMissingResource=true]   # CRDs arrive with the karpenter app
    retry: { limit: 10, backoff: { duration: 15s, factor: 2, maxDuration: 5m } }
```

### `gitops/platform-config/karpenter/nodes.yaml`

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  role: dkm-karpenter-node               # from: scripts/tf.sh platform output karpenter_node_role_name
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
    - tags: { karpenter.sh/discovery: dkm }
  securityGroupSelectorTerms:
    - tags: { karpenter.sh/discovery: dkm }
  metadataOptions:
    httpTokens: required                  # IMDSv2 only
    httpPutResponseHopLimit: 2
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: [spot, on-demand]       # spot first; on-demand only if no spot capacity
        - key: kubernetes.io/arch
          operator: In
          values: [amd64, arm64]          # arm64 = Graviton, cheaper; the image is multi-arch (Phase 6)
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: [t, c, m]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: [medium, large]
      expireAfter: 168h                   # replace nodes weekly, so they always run a patched AMI
  limits:
    cpu: "8"                              # ⚠️ hard ceiling: Karpenter will never run more than 8 vCPUs in total
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m                  # remove idle nodes quickly to save money
```

---

## 4.6 Push, then hand over to Argo CD

Argo CD reads from GitHub, not from your PC, so **push first**:

```bash
git add gitops
git commit -m "Bootstrap Argo CD and platform add-ons as Applications"
git push

kubectl apply -f gitops/bootstrap/karpenter-oci-repo.yaml
kubectl apply -f gitops/bootstrap/root.yaml
```

Watch it in the UI, or:

```bash
kubectl -n argocd get applications -w
# after 2–5 minutes every app shows SYNC STATUS Synced and HEALTH Healthy
```

---

## 4.7 A script for the start of every session

From now on a session starts with infrastructure, Argo CD and the root app. `scripts/session-up.sh`:

```bash
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
  --version ‹argocd chart› -f gitops/bootstrap/argocd-values.yaml --wait

# Only the Kubernetes objects: argocd-values.yaml in the same folder is a Helm values file, not a manifest.
kubectl apply -f gitops/bootstrap/karpenter-oci-repo.yaml -f gitops/bootstrap/root.yaml
echo "Argo CD is syncing. Watch with: kubectl -n argocd get applications -w"
```

```bash
git update-index --chmod=+x scripts/session-up.sh   # so it's executable on Linux/macOS too
```

⚠️ `-auto-approve` is acceptable here only because this stack's plan is the same every session. If you changed
anything in `infra/platform`, run `scripts/tf.sh platform plan` yourself first.

---

## ✅ Phase 4 checkpoint

```bash
kubectl -n argocd get applications
# NAME                           SYNC STATUS   HEALTH STATUS
# aws-load-balancer-controller   Synced        Healthy
# external-dns                   Synced        Healthy
# external-secrets               Synced        Healthy
# karpenter                      Synced        Healthy
# karpenter-nodes                Synced        Healthy
# platform                       Synced        Healthy

kubectl get nodepool,ec2nodeclass                 # default / default, READY True
```

**Prove Karpenter works** by asking for more CPU than the system nodes have. Expect a node in under a minute
(the first run of this guide got a spot `t2.medium` in 46 seconds) and its removal about 2 minutes after the
deployment is deleted:

```bash
kubectl create deployment inflate --image=public.ecr.aws/eks-distro/kubernetes/pause:3.9 --replicas=0
kubectl set resources deployment inflate --requests=cpu=1
kubectl scale deployment inflate --replicas=3
kubectl get nodeclaims -w        # within ~60 s a claim appears, then a node joins (often a spot t-/c- type)

kubectl delete deployment inflate
kubectl get nodes -w             # about 1–2 minutes later, consolidation removes the extra node
```

### If something goes wrong

| Symptom | Fix |
|---|---|
| App stuck `Unknown` / `ComparisonError` mentioning OCI | The `karpenter-oci` repository secret wasn't applied. `kubectl apply -f gitops/bootstrap/karpenter-oci-repo.yaml`. |
| Load Balancer Controller logs `failed to get VPC ID` | Pods can't read instance metadata (the nodes' hop limit is 1, deliberately). Check `vpcTags: { Name: dkm }` is in its values and that the VPC's `Name` tag is `dkm`: `aws ec2 describe-vpcs --filters Name=tag:Name,Values=dkm`. Don't raise the hop limit: that would let every pod use the node's IAM role. |
| Karpenter logs `no subnets found` in its first minute | A start-up race: it asked before reading the EC2NodeClass. If `kubectl get ec2nodeclass default` shows `READY True` and the errors stop, ignore it. If they continue, the private subnets are missing the `karpenter.sh/discovery: dkm` tag. |
| NodeClaim stays `Unknown`, Karpenter logs mention `AccessDenied` | The Pod Identity association for `kube-system/karpenter` is missing. Check `aws eks list-pod-identity-associations --cluster-name dkm`. |
| No NodeClaim appears at all | `kubectl -n kube-system logs deploy/karpenter`. Usually the `interruptionQueue` name is wrong. |
| ExternalDNS logs `AccessDenied` on Route 53 | Its zone ARN in `pod-identity.tf` must be the `danielkojomegbenu.com` zone. |

## Commit

```bash
git add scripts gitops
git commit -m "Add session-up script"
git push
```

> ### 🛑 End of session
> Karpenter nodes are created by Karpenter, not Terraform, so they must go first or `terraform destroy`
> gets stuck on the VPC. Deleting the NodePool directly doesn't work: Argo CD's self-heal puts it straight back.
> Remove it through Argo CD instead:
> ```bash
> kubectl -n argocd delete application platform          # root app: stops it recreating its children (they keep running)
> kubectl -n argocd delete application karpenter-nodes   # its finalizer deletes the NodePool; Karpenter terminates its nodes
> kubectl get nodeclaims -w                              # wait until this is empty, then Ctrl+C
> scripts/tf.sh platform destroy
> ```
> [Phase 12](12-portfolio-and-teardown.md#teardown) turns this into a `session-down.sh` script that also handles
> load balancers.

**Next:** [Phase 5: Database and secrets](05-database-and-secrets.md)
