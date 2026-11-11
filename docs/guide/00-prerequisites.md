# Phase 0: Prerequisites and cost plan

**Goal:** every tool installed, every account ready, the budget alert raised, and the `remodelled` branch of
`dkojo/dkmwebapp` ready, before anything in AWS costs money.

**Time:** 1–2 hours · **Cost:** $0

---

## 0.1 Tools on your PC

You already have Git, the AWS CLI, Terraform, Node.js, the GitHub CLI and VS Code from the portfolio build.
Install the rest with `winget` in **PowerShell**, then **close and reopen VS Code**:

```powershell
winget install Kubernetes.kubectl
winget install Helm.Helm
winget install Docker.DockerDesktop          # needs a restart; enable the WSL 2 backend when asked
winget install EclipseAdoptium.Temurin.21.JDK
winget install Sigstore.Cosign
winget install AquaSecurity.Trivy
winget install Kyverno.kyverno-cli           # optional, for testing policies locally
winget install argoproj.argocd               # optional, the Argo CD CLI
winget install Derailed.k9s                  # optional, a terminal UI for the cluster
winget install jqlang.jq
```

If `winget` can't find a package, search for it: `winget search kubectl`.

### ✅ Checkpoint 0.1

```bash
kubectl version --client      # Client Version: v1.3x
helm version --short          # v3.x or v4.x
docker version --format '{{.Server.Version}}'   # a version, not an error (Docker Desktop must be running)
java -version                 # openjdk version "21..."
cosign version                # GitVersion: v2.x or later
trivy --version               # Version: 0.6x
terraform version             # Terraform v1.12 (already installed)
aws --version                 # aws-cli/2.x (already installed)
jq --version
```

---

## 0.2 AWS: check who you are and raise the budget

```bash
aws sts get-caller-identity --query Arn --output text
# arn:aws:iam::‹account›:user/Didioslinq   (an IAM user, not root)
```

⚠️ **Raise the budget alert now.** It's $3/month for the portfolio and covers the whole account, so it would
fire on day one of this project. In the **portfolio** repo:

```bash
cd /c/Users/User/portfolio-website/infra
# edit terraform.tfvars:  monthly_budget_usd = 40
terraform plan     # expect: 1 to change (aws_budgets_budget.monthly)
terraform apply
cd -
```

$40 covers roughly 15 eight-hour sessions. The alert emails you at 80% of actual spend and when the month's
**forecast** passes 100%. A forecast alert is often the first sign that a cluster was left running overnight.

💡 **Free extra safety net:** AWS Cost Anomaly Detection (Billing console → Cost Anomaly Detection → create a
monitor for "AWS services" with a daily email). It notices unusual spend without you setting a number.

---

## 0.3 Accounts you'll need (all free)

| Service | Why | What to do now |
|---|---|---|
| **SonarQube Cloud** (sonarcloud.io) | Static analysis and the quality gate in CI. Free for public repos. | Sign in with GitHub. Create an **organization** linked to your GitHub account (`dkojo`). Note the organization key. |
| **Slack** | Build failures, deploy notices, alerts | Create a free workspace (or use one you have), make a channel `#deployments`. Phase 6 adds the webhook. |

---

## 0.4 Rename the repository and create the `remodelled` branch

You're rebuilding your 2024 project in its own repository, so its history ("designed 2024, rebuilt 2026")
stays in one place. Three things happen here: the repo gets its new name, you clone it, and a new branch
called `remodelled` holds the rebuild while `main` keeps the 2024 version untouched.

**Rename the repo on GitHub.** GitHub redirects the old name, so existing links and clones keep working:

```bash
gh repo rename dkmwebapp --repo dkojo/itgenius-springbootapp-cicd --yes
gh repo view dkojo/dkmwebapp --json name,url     # "name":"dkmwebapp"
```

**Clone it and create the branch:**

```bash
cd /c/Users/User
gh repo clone dkojo/dkmwebapp
cd dkmwebapp
git switch -c remodelled
```

**Move the 2024 files into `legacy-2024/`.** The rebuild uses its own layout (`app/`, `infra/`, `gitops/`),
and keeping the old Jenkins version in one folder means nothing gets mixed up, while anyone reading the repo
can still compare the two:

```bash
mkdir legacy-2024
git mv .mvn Dockerfile README.md SeedJobDSL.groovy ansible monolithic-cicd mvnw mvnw.cmd \
  pipelines_list.json pom.xml secrets-manager src terraform legacy-2024/
ls -A              # only .git and legacy-2024 left
```

If `git mv` reports a file that doesn't exist, run `ls -A` and move whatever is there except `.git`.

**Bring in this guide** and set line endings:

```bash
cp -r /c/Users/User/eks-gitops-platform/docs .
printf '* text=auto eol=lf\n*.png binary\n*.jpg binary\n' > .gitattributes
```

From now on, use the copy in `C:\Users\User\dkmwebapp\docs\guide`. The old `eks-gitops-platform` folder can
be deleted once this phase is done.

Create `.gitignore`:

```gitignore
# Terraform
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
crash.log

# Java / Maven
app/target/
target/
*.class

# Editors and OS
.vscode/*
!.vscode/extensions.json
.idea/
.DS_Store

# Local env files
.env
*.local
```

Commit and publish the branch:

```bash
git add -A
git status --short | head -20    # renames into legacy-2024/, plus docs/, .gitattributes, .gitignore
git commit -m "Start the 2026 rebuild: move the 2024 Jenkins version into legacy-2024 and add the build guide"
git push -u origin remodelled
gh repo edit dkojo/dkmwebapp \
  --description "dkmwebapp: scanned, signed, canary-released Java service on Amazon EKS with GitOps" \
  --add-topic eks,kubernetes,terraform,gitops,argocd,devsecops,aws
```

💡 All work in this guide happens on `remodelled`. Wherever a step says `git push`, it pushes `remodelled`.

---

## 0.5 Record the repo's OIDC subject (you'll need it in Phase 2)

When GitHub Actions signs in to AWS, its token names the repo in a "subject". Your portfolio repo uses the
numbered (immutable) form, which is why its first deploy failed. Check which form this repo uses:

```bash
gh api repos/dkojo/dkmwebapp/actions/oidc/customization/sub
# {"use_default":true,"use_immutable_subject":false,"sub_claim_prefix":"repo:dkojo/dkmwebapp"}
```

Write down the `sub_claim_prefix` value. With `"use_immutable_subject": false` it's simply
`repo:dkojo/dkmwebapp`. (Before the rename it read `repo:dkojo/itgenius-springbootapp-cicd`, so run this
**after** 0.4.)

---

## 0.6 The names used in this guide

These names are used throughout. Changing them later means editing many files.

| Thing | Value |
|---|---|
| GitHub repository and branch | `dkojo/dkmwebapp`, branch `remodelled` |
| AWS region | `us-east-1` |
| Cluster name | `dkm` |
| App name / ECR repository / Helm chart | `dkmwebapp` |
| Java package | `com.danielmegbenu.dkmwebapp` |
| Kubernetes namespace for the app | `dkm` |
| Database name and secret prefix | `dkm`, secrets under `dkm/` |
| App URL | `app.danielkojomegbenu.com` (your existing Route 53 zone) |
| Terraform state | existing bucket `danielkojomegbenu-tfstate`, keys under `eks/` |

---

## ✅ Phase 0 checkpoint

- [ ] Every command in Checkpoint 0.1 prints a version
- [ ] `aws sts get-caller-identity` shows your IAM user
- [ ] The budget is raised to $40 (`terraform plan` in the portfolio `infra/` shows no changes)
- [ ] SonarQube Cloud organization exists and you know its key
- [ ] Slack workspace with `#deployments`
- [ ] `github.com/dkojo/dkmwebapp/tree/remodelled` shows `legacy-2024/` and `docs/guide/`
- [ ] You've written down the OIDC `sub_claim_prefix` (`repo:dkojo/dkmwebapp`)

**Next:** [Phase 1: Repository and sample app](01-repo-and-app.md)
