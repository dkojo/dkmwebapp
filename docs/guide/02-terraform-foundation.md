# Phase 2: Terraform foundation

**Goal:** the parts that cost almost nothing and **stay up permanently**: the ECR repository, the IAM role
GitHub Actions uses to push images, and the HTTPS certificate for `app.danielkojomegbenu.com`.

**Time:** about 1 hour · **Cost:** a few cents a month (ECR storage). The certificate and IAM role are free.

Why a separate stack: in Phase 3 you'll create and destroy the expensive `platform` stack every session.
Images, the CI role and the certificate survive that, so CI keeps working and the certificate never has to be
re-validated.

---

## 2.1 Files

Create `infra/foundation/` with these files.

**Reusable by design.** Nothing environment-specific is written into the `.tf` files. Region, names, domain,
branches and limits are variables, and their values live in one file per environment in `envs/`:
`envs/prod.tfvars` (the values) and `envs/prod.backend.hcl` (where the state lives). Another account, region or
app is a new pair of files, not a code change. `scripts/tf.sh` (end of this section) passes the right pair to
Terraform, so you never type `-var-file` or `-backend-config` yourself.

### `versions.tf`

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial backend: the bucket, key and region come from envs/<env>.backend.hcl at init time
  # (scripts/tf.sh does this), so the same code can keep separate state per environment or account.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project   = var.app_name
      Stack     = "foundation"
      ManagedBy = "terraform"
      Repo      = var.github_repo
    }
  }
}
```

### `variables.tf`

```hcl
variable "aws_region" {
  description = "Region for every resource in this stack"
  type        = string
  default     = "us-east-1"
}

variable "app_name" {
  description = "Names the ECR repository and the Project tag"
  type        = string
  default     = "dkmwebapp"
}

variable "name_prefix" {
  description = "Prefix for IAM names, e.g. eks-dkm gives the role eks-dkm-ci"
  type        = string
  default     = "eks-dkm"
}

variable "github_repo" {
  description = "owner/name of the repository whose workflows build the app"
  type        = string
}

variable "github_oidc_subject_prefix" {
  description = "From Phase 0.5: gh api repos/<owner>/<repo>/actions/oidc/customization/sub"
  type        = string
}

variable "ci_branches" {
  description = "Branches whose workflow runs may push images. Pull requests never get AWS access."
  type        = list(string)
  default     = ["remodelled"]
}

variable "domain_name" {
  description = "Existing Route 53 public zone the certificate is validated in"
  type        = string
}

variable "app_hostname" {
  description = "Hostname the certificate covers"
  type        = string
}

variable "ecr_keep_images" {
  description = "How many recent images ECR keeps"
  type        = number
  default     = 50
}

variable "ecr_untagged_expiry_days" {
  description = "Days before untagged layers are deleted"
  type        = number
  default     = 14
}
```

### `envs/prod.tfvars`: this environment's values

```hcl
# Production settings for infra/foundation. Used by: scripts/tf.sh foundation <command>
aws_region                 = "us-east-1"
app_name                   = "dkmwebapp"
name_prefix                = "eks-dkm"
github_repo                = "dkojo/dkmwebapp"
github_oidc_subject_prefix = "repo:dkojo@167027053/dkmwebapp@893369381" # immutable form, from Phase 0.5
ci_branches                = ["remodelled"]
domain_name                = "danielkojomegbenu.com"
app_hostname               = "app.danielkojomegbenu.com"
```

### `envs/prod.backend.hcl`: where this environment's state lives

```hcl
# Where infra/foundation keeps its state for this environment. S3 native locking, no DynamoDB.
bucket       = "danielkojomegbenu-tfstate"
key          = "eks/foundation.tfstate"
region       = "us-east-1"
encrypt      = true
use_lockfile = true
```

### `ecr.tf`

```hcl
resource "aws_ecr_repository" "app" {
  name = var.app_name

  # Tags stay mutable on purpose: Cosign stores signatures as tags (sha256-<digest>.sig), and a re-run of the
  # signing step would fail on an immutable repository. Integrity comes from deploying by digest instead:
  # the GitOps values pin image@sha256:..., which can never point at different content.
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged layers after ${var.ecr_untagged_expiry_days} days"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = var.ecr_untagged_expiry_days }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the ${var.ecr_keep_images} most recent images"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = var.ecr_keep_images }
        action       = { type = "expire" }
      }
    ]
  })
}
```

### `github-ci.tf`: the role CI uses to push images

```hcl
# Your account already has GitHub's OIDC provider (the portfolio uses it), so reference it.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "ci_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only workflow runs on the listed branches may push images. Pull requests build and scan, but never touch AWS.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for b in var.ci_branches : "${var.github_oidc_subject_prefix}:ref:refs/heads/${b}"]
    }
  }
}

resource "aws_iam_role" "ci" {
  name               = "${var.name_prefix}-ci"
  description        = "GitHub Actions in ${var.github_repo} pushes images to ECR"
  assume_role_policy = data.aws_iam_policy_document.ci_trust.json
}

data "aws_iam_policy_document" "ci" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action has no resource-level permissions
  }
  statement {
    sid = "PushToDkmwebapp"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
      "ecr:PutImage", "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.app.arn]
  }
}

resource "aws_iam_role_policy" "ci" {
  name   = "push-${var.app_name}"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci.json
}
```

### `certificate.tf`: HTTPS for the app, validated in your existing zone

```hcl
data "aws_route53_zone" "main" {
  name = var.domain_name
}

resource "aws_acm_certificate" "app" {
  domain_name       = var.app_hostname
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "app_cert_validation" {
  for_each = {
    for o in aws_acm_certificate.app.domain_validation_options : o.domain_name => o
  }
  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 300
}

resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in aws_route53_record.app_cert_validation : r.fqdn]
}
```

### `outputs.tf`

```hcl
output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "ci_role_arn" {
  value     = aws_iam_role.ci.arn
  sensitive = true # contains the account ID; keep it out of logs
}

output "app_certificate_arn" {
  value     = aws_acm_certificate_validation.app.certificate_arn
  sensitive = true
}

output "route53_zone_id" {
  value = data.aws_route53_zone.main.zone_id
}
```

---

### `scripts/tf.sh` (repo root): run any stack with any environment

```bash
#!/usr/bin/env bash
# Run Terraform for one stack with one environment's settings and state.
#
#   scripts/tf.sh <foundation|platform> <terraform command> [args...]
#   ENV=dev scripts/tf.sh platform plan        # ENV defaults to prod
#
# Each stack keeps per-environment files in infra/<stack>/envs/:
#   <env>.tfvars        variable values (region, names, sizes...)
#   <env>.backend.hcl   where that environment's state lives
#   <env>.local.tfvars  optional, git-ignored: values that must stay out of a public repo (your IP)
set -euo pipefail

usage="usage: [ENV=<env>] scripts/tf.sh <foundation|platform> <command> [args...]"
stack=${1:?$usage}; shift
cmd=${1:?$usage}; shift
env=${ENV:-prod}
dir="$(cd "$(dirname "$0")/.." && pwd)/infra/$stack"

for f in "envs/$env.tfvars" "envs/$env.backend.hcl"; do
  [ -f "$dir/$f" ] || { echo "missing infra/$stack/$f" >&2; exit 1; }
done

tf() { terraform -chdir="$dir" "$@"; }

varfiles=(-var-file="envs/$env.tfvars")
[ -f "$dir/envs/$env.local.tfvars" ] && varfiles+=(-var-file="envs/$env.local.tfvars")

# -reconfigure only switches which state file this folder points at; it never moves or copies state.
init() { tf init -input=false -reconfigure -backend-config="envs/$env.backend.hcl" "$@"; }

case "$cmd" in
  init) init "$@"; exit ;;
esac
init >/dev/null

case "$cmd" in
  apply)
    # A saved plan already contains its variables; Terraform refuses -var-file with one.
    if [ $# -gt 0 ] && [[ "${!#}" == *.tfplan ]]; then tf apply "$@"; else tf apply "${varfiles[@]}" "$@"; fi ;;
  plan|destroy|import|refresh|console)
    tf "$cmd" "${varfiles[@]}" "$@" ;;
  *)
    tf "$cmd" "$@" ;;   # output, state, fmt, validate, show...
esac
```

```bash
git update-index --chmod=+x scripts/tf.sh   # executable on Linux/macOS too
```

`ENV` picks the environment (default `prod`): `ENV=dev scripts/tf.sh platform plan` reads
`infra/platform/envs/dev.tfvars` and uses that environment's own state.

---

## 2.2 Apply

```bash
terraform -chdir=infra/foundation fmt -check -recursive
scripts/tf.sh foundation validate
scripts/tf.sh foundation plan -out=foundation.tfplan
```

**Read the plan before applying.** Expect **7 to add, 0 to change, 0 to destroy**:
ECR repository + lifecycle policy, CI role + policy, certificate + 1 validation record + validation.
⚠️ If it shows anything to **change** or **destroy**, stop. Something already exists with the same name.

```bash
scripts/tf.sh foundation apply foundation.tfplan
rm infra/foundation/foundation.tfplan
```

The certificate validates in 1–5 minutes, because your zone is already on Route 53.

---

## 2.3 Save values for later phases

```bash
scripts/tf.sh foundation output -raw ecr_repository_url     # ‹account›.dkr.ecr.us-east-1.amazonaws.com/dkmwebapp
```

The ECR URL contains your account ID. That's normal: it will appear in your GitOps values file, and AWS doesn't
treat account IDs as secrets. The things that must never appear in Git are **credentials**.

---

## ✅ Phase 2 checkpoint

```bash
aws ecr describe-repositories --repository-names dkmwebapp \
  --query 'repositories[0].{scan:imageScanningConfiguration.scanOnPush,mutability:imageTagMutability}'
# { "scan": true, "mutability": "MUTABLE" }

aws acm list-certificates --query "CertificateSummaryList[?DomainName=='app.danielkojomegbenu.com'].Status" --output text
# ISSUED

aws iam get-role --role-name eks-dkm-ci \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals."token.actions.githubusercontent.com:sub"' --output text
# repo:dkojo@167027053/dkmwebapp@893369381:ref:refs/heads/remodelled

scripts/tf.sh foundation plan    # No changes.
```

### If something goes wrong

| Symptom | Fix |
|---|---|
| `no matching Route 53 Hosted Zone found` | The zone lives in the same account (it's the portfolio's). Check `aws route53 list-hosted-zones`. |
| Certificate stuck in `PENDING_VALIDATION` | `aws route53 list-resource-record-sets --hosted-zone-id ‹zone›` should show a `_xxxx.app` CNAME. Wait 10 minutes. |
| `Error acquiring the state lock` | Another `terraform` is running, or one crashed. If you're sure none is running: `terraform force-unlock ‹id›`. |

## Commit

```bash
git add infra/foundation scripts/tf.sh
git commit -m "Add Terraform foundation: ECR, CI push role, app certificate"
git push
```

This stack stays up for the life of the project. You won't destroy it at the end of sessions.

**Next:** [Phase 3: EKS cluster](03-eks-cluster.md)
