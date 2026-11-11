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

  # Same state bucket as the portfolio, different key. S3 native locking, no DynamoDB.
  backend "s3" {
    bucket       = "danielkojomegbenu-tfstate"
    key          = "eks/foundation.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project   = "dkmwebapp"
      Stack     = "foundation"
      ManagedBy = "terraform"
      Repo      = "dkojo/dkmwebapp"
    }
  }
}
```

### `variables.tf`

```hcl
variable "app_name" {
  type    = string
  default = "dkmwebapp"
}

variable "domain_name" {
  description = "Existing Route 53 zone (created by the portfolio repo)"
  type        = string
  default     = "danielkojomegbenu.com"
}

variable "app_hostname" {
  type    = string
  default = "app.danielkojomegbenu.com"
}

variable "github_oidc_subject_prefix" {
  description = "From Phase 0.5: gh api repos/dkojo/dkmwebapp/actions/oidc/customization/sub"
  type        = string
}
```

### `terraform.tfvars`

```hcl
github_oidc_subject_prefix = "repo:dkojo@167027053/dkmwebapp@893369381" # immutable form, from Phase 0.5
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
        description  = "Remove untagged layers after 14 days"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 14 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 50 most recent images"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 50 }
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
    # Only workflow runs on remodelled may push images. Pull requests build and scan, but never touch AWS.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.github_oidc_subject_prefix}:ref:refs/heads/remodelled"]
    }
  }
}

resource "aws_iam_role" "ci" {
  name               = "eks-dkm-ci"
  description        = "GitHub Actions in dkojo/dkmwebapp pushes images to ECR"
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
  name   = "push-dkmwebapp"
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

## 2.2 Apply

```bash
cd infra/foundation
terraform init
terraform fmt -check && terraform validate
terraform plan -out=foundation.tfplan
```

**Read the plan before applying.** Expect **7 to add, 0 to change, 0 to destroy**:
ECR repository + lifecycle policy, CI role + policy, certificate + 1 validation record + validation.
⚠️ If it shows anything to **change** or **destroy**, stop. Something already exists with the same name.

```bash
terraform apply foundation.tfplan
rm foundation.tfplan
cd ../..
```

The certificate validates in 1–5 minutes, because your zone is already on Route 53.

---

## 2.3 Save values for later phases

```bash
cd infra/foundation
terraform output -raw ecr_repository_url     # ‹account›.dkr.ecr.us-east-1.amazonaws.com/dkmwebapp
cd ../..
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

terraform -chdir=infra/foundation plan    # No changes.
```

### If something goes wrong

| Symptom | Fix |
|---|---|
| `no matching Route 53 Hosted Zone found` | The zone lives in the same account (it's the portfolio's). Check `aws route53 list-hosted-zones`. |
| Certificate stuck in `PENDING_VALIDATION` | `aws route53 list-resource-record-sets --hosted-zone-id ‹zone›` should show a `_xxxx.app` CNAME. Wait 10 minutes. |
| `Error acquiring the state lock` | Another `terraform` is running, or one crashed. If you're sure none is running: `terraform force-unlock ‹id›`. |

## Commit

```bash
git add infra/foundation
git commit -m "Add Terraform foundation: ECR, CI push role, app certificate"
git push
```

This stack stays up for the life of the project. You won't destroy it at the end of sessions.

**Next:** [Phase 3: EKS cluster](03-eks-cluster.md)
