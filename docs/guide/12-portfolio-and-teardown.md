# Phase 12: Portfolio, documentation and teardown

**Goal:** the project connected to your portfolio's live pipeline view, documented and screenshotted, and a
one-command teardown you trust, so leaving the platform switched off between sessions is the normal state.

**Time:** about 2 hours · **Cost:** $0 once torn down (the foundation stack and the Slack secret: under $1/month)

---

## 12.1 Teardown

Destroying things in the wrong order is the most common way this kind of project leaves surprise charges:
Kubernetes created some AWS resources (the ALB, EBS volumes, Karpenter's EC2 instances) that Terraform doesn't
know about. They have to go **through Kubernetes first**, then Terraform destroys the rest.

### `scripts/session-down.sh`

```bash
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
```

### `scripts/check-leftovers.sh`

Run it on its own any time you're unsure whether something is still running:

```bash
#!/usr/bin/env bash
# Lists billable resources that should not exist after session-down. Exit code 1 if any are found, or if a
# check couldn't run (an AWS error must never read as "none").
# Account-wide: if you run other things in us-east-1, some lines may be yours and expected.
set -uo pipefail
found=0
check() {   # check <label> <aws cli args…>
  local out
  if ! out=$(aws "${@:2}" --output text 2>&1); then
    echo "❓ $1: check failed: $(echo "$out" | grep -m1 .)"; found=1; return
  fi
  out=$(echo "$out" | tr -s '\t\r\n' ' ')
  if [ -n "${out// /}" ] && [ "$out" != "None " ]; then echo "⚠️  $1: $out"; found=1; else echo "✅ $1: none"; fi
}
check "EKS clusters"            eks list-clusters --query 'clusters'
check "k8s load balancers"      elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'k8s-')].LoadBalancerName"
check "Karpenter instances"     ec2 describe-instances --filters Name=tag-key,Values=karpenter.sh/nodepool Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[].InstanceId'
check "NAT gateways"            ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId'
check "Unattached EBS volumes"  ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'
check "Unattached Elastic IPs"  ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp'
check "RDS instances"           rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
check "WAF web ACLs"            wafv2 list-web-acls --scope REGIONAL --query 'WebACLs[].Name'
[ "$found" = 0 ] && echo "All clear: nothing billable left from the platform." || echo "Something is still running, or couldn't be checked: see ⚠️/❓ lines."
exit "$found"
```

```bash
git update-index --chmod=+x scripts/session-down.sh scripts/check-leftovers.sh
git add scripts && git commit -m "Add ordered teardown and leftover check" && git push
```

### Your session routine from now on

```
start:  scripts/session-up.sh          # ~20 min: Terraform, Argo CD, then everything syncs from Git
work …
stop:   scripts/session-down.sh        # ~15 min; ends with "All clear"
```

⚠️ If `session-down.sh` stops with a timeout, **don't** run `terraform destroy` by hand. Find what's stuck
(`kubectl get ingress,pv,nodeclaims -A`), fix that, and run the script again.

**The day after each session**, glance at **Billing → Bills** or Cost Explorer (group by service, daily). EKS and
EC2 lines should stop on the day you tore down.

---

### Make `remodelled` the branch visitors see

Recruiters who open the repo land on the default branch, which is still the 2024 version on `main`.
Make the rebuild the front page (this also switches Dependabot on, see Phase 6.5):

```bash
gh repo edit dkojo/dkmwebapp --default-branch remodelled
```

`main` stays as it is, so the 2024 version is still one click away, and `legacy-2024/` has it too.

## 12.2 Connect the portfolio's live pipeline view

In the **portfolio** repo:

### `src/data/projects.json`: the `eks-gitops-platform` entry

```json
"result": "Signed, scanned and canary-released",
"github": "https://github.com/dkojo/dkmwebapp/tree/remodelled",
"pipelineRepo": "dkojo/dkmwebapp",
"outcome": "‹your real results, e.g.: a bad release was caught at 10% traffic and rolled back automatically in ‹N› minutes; unsigned images are rejected by the cluster; the whole platform is rebuilt from Git in about 20 minutes›"
```

Write the outcome from **what you measured**, not from this guide. Recruiters ask about the numbers.

### `src/data/pipeline.json`: make the diagram match what you built

| Node | Change if… |
|---|---|
| `ecr` | `"sub": "deploy by digest"`, and update `role`/`why`: tags are mutable, deployments pin digests (Phase 2) |
| `cf` | If you built Phase 11 as WAF on the ALB: `"label": "AWS WAF"`, `"sub": "managed rules · ALB"`, and rewrite `role` |
| `rds` | `"sub": "private · encrypted"` (single-AZ in this build; mention Multi-AZ as the production setting) |

```bash
cd /c/Users/User/portfolio-website
npm run dev     # check /projects/eks-gitops-platform
git commit -am "Connect the EKS case study to its real pipeline" && git push   # deploys automatically
```

On the live page, the status bar should now say **"Live from GitHub Actions"** and link to your latest run.
The GitHub Actions boxes (Gitleaks → … → Slack) show real results. Argo CD, Kyverno and the cluster stay
neutral, because that part runs outside GitHub.

---

## 12.3 Screenshots worth taking (save to `docs/screenshots/`)

Take them while a session is running, ideally all in the same session:

1. GitHub Actions run: every step green, including Cosign and the digest bump
2. A pull request where **Gitleaks** or **Trivy** failed the build (Phase 6)
3. SonarQube Cloud project overview with the passed quality gate
4. Argo CD UI: the application tree for `dkmwebapp` (Rollout, ReplicaSets, Services, Ingress)
5. **Aborted canary**: `kubectl argo rollouts get rollout` showing `RolloutAborted`, plus the failed AnalysisRun
6. Kyverno denying the unsigned image from your own ECR (Phase 9, test 3)
7. Grafana: a Tempo trace with the HTTP span and its JDBC child span
8. Grafana: request rate and error rate during the bad-release test
9. Slack `#deployments`: a CI ✅, an Argo CD 🚀 and an alert 🔥
10. Karpenter: `kubectl get nodeclaims` with a **spot** arm64 node
11. Optional: WAF sampled requests showing the blocked SQL-injection attempt

Copy the best three or four into the portfolio repo (`src/assets/screenshots/`) for the case study page.

---

## 12.4 The repository README

The README is often all a recruiter reads. Structure it like this:

```markdown
# EKS GitOps Platform

One-paragraph summary: what it is, and the three results you're proudest of.

[Live pipeline and architecture →](https://danielkojomegbenu.com/projects/eks-gitops-platform)

## Architecture
(diagram: screenshot of the portfolio diagram, or the mermaid chart from docs/guide/README.md)

## What happens on `git push`
Numbered list of the pipeline, 1 line per stage, linking to the workflow file.

## Security, by layer
Gitleaks · SonarQube · Trivy (image + IaC) · Cosign keyless + SBOM · Kyverno signature/allow-list ·
Pod Security "restricted" · Pod Identity per add-on · Secrets Manager + External Secrets · WAF · no stored keys (OIDC)

## Results
Real numbers: rollback time, image size, pipeline duration, cost per session.

## Run it yourself
Prerequisites, then `scripts/session-up.sh` / `scripts/session-down.sh`, and a link to docs/guide/.

## Cost
The table from docs/guide/README.md, and the session model.

## What I'd do differently in production
(see 12.5)
```

---

## 12.5 What I'd do differently in production

Interviewers like this section. It shows you know where the demo cut corners and why.

- **NAT gateway per AZ** instead of one (an AZ outage would cut egress for the others).
- **RDS Multi-AZ**, deletion protection, final snapshots, and **RDS-managed password rotation** instead of a
  Terraform-generated password (Phase 5 explains why the demo didn't).
- **Separate AWS accounts** for dev, staging and prod (AWS Organizations), and **promotion between
  environments by pull request** in the GitOps repo.
- **Private EKS API endpoint** reached through a VPN or SSM, instead of a public endpoint with an IP allow-list.
- **Kyverno with three replicas** and a PodDisruptionBudget: its webhook fails closed.
- **Long-term metric and log storage** in S3 (Thanos or Mimir, Loki in S3 mode) instead of 2-day volumes.
- **Terraform in CI** (plan on pull request, apply on merge, with Infracost comments), not from a laptop.
- **CloudFront in front** if the service served static assets or global users (Phase 11).
- **Least-privilege database user** for the app, created by a migration, instead of the master user.

---

## ✅ Final checkpoint: the project is done when…

- [ ] `scripts/session-up.sh` brings the whole platform up from nothing, with no manual steps after it
- [ ] A push to `app/` reaches `https://app.danielkojomegbenu.com` through a canary, with no `kubectl` from you
- [ ] A bad release is rolled back automatically (screenshot taken)
- [ ] An unsigned image is rejected (screenshot taken)
- [ ] Metrics, logs and traces visible in Grafana; an alert has reached Slack
- [ ] `scripts/session-down.sh` ends with **"All clear"**, and the next day's bill shows no EKS charges
- [ ] The portfolio's case study shows **"Live from GitHub Actions"** and links to the repo
- [ ] The repo README has results with real numbers, and the "production" section

Congratulations: that's a complete, defensible platform project, end to end.
