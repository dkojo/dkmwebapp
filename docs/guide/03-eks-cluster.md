# Phase 3: EKS cluster

**Goal:** a VPC across three availability zones, an EKS cluster with two small system nodes, the AWS
resources Karpenter needs, and Pod Identity roles for every add-on, all in the `platform` stack that you create
and destroy each session.

**Time:** about 2 hours (Terraform itself runs 15–20 minutes) · **💰 Cost while running: about $0.25/hour**

---

## 3.1 Pick the Kubernetes version

```bash
aws eks describe-cluster-versions --query "clusterVersions[?status=='STANDARD_SUPPORT'].clusterVersion" --output text
# e.g. 1.33  1.34  1.35  → use the newest one
```

⚠️ Avoid versions in **extended support**. They cost **$0.60/hour** instead of $0.10.

## 3.2 Find your public IP

The cluster's API endpoint will only accept connections from your IP:

It goes in a separate file that git ignores (`*.local.tfvars` in `.gitignore`): this repo is public, and your home
IP is both personal and the one thing standing between the internet and your cluster's API.

```bash
cat > infra/platform/envs/prod.local.tfvars <<EOF
# Not committed (*.local.tfvars is git-ignored). Your public IP, from step 3.2.
admin_cidrs = ["$(curl -s https://checkip.amazonaws.com)/32"]
EOF
git check-ignore infra/platform/envs/prod.local.tfvars   # must print the path; if not, add *.local.tfvars to .gitignore
```

`scripts/tf.sh` adds `envs/<env>.local.tfvars` to every plan and apply when the file exists.

If your home IP changes later, `kubectl` will time out. Update `admin_cidrs` in `envs/prod.local.tfvars` and run `scripts/tf.sh platform apply` again.

---

## 3.3 Files: `infra/platform/`

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
  # Partial backend: bucket, key and region come from envs/<env>.backend.hcl (scripts/tf.sh passes it)
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.app_name
      Environment = var.environment
      Stack       = "platform"
      ManagedBy   = "terraform"
      Repo        = var.github_repo
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
```

### `variables.tf`

```hcl
# ---- Identity and placement ----
variable "environment" {
  description = "Environment name, e.g. prod or dev. Tags every resource."
  type        = string
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  description = "Names the VPC, cluster and every role and resource derived from it"
  type        = string
  default     = "dkm"
}

variable "app_name" {
  type    = string
  default = "dkmwebapp"
}

variable "github_repo" {
  type    = string
  default = "dkojo/dkmwebapp"
}

variable "domain_name" {
  description = "Existing Route 53 public zone ExternalDNS may write to"
  type        = string
}

# ---- Network ----
variable "vpc_cidr" {
  description = "VPC range. Subnets are carved from it automatically: a /20 private, /24 public and /24 database per AZ."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "How many availability zones to spread across"
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "true: one NAT for all AZs (about $65/month cheaper). Production: false, one per AZ."
  type        = bool
  default     = true
}

# ---- Cluster ----
variable "kubernetes_version" {
  description = "Newest version in standard support (step 3.1)"
  type        = string
}

variable "admin_cidrs" {
  description = "IPs allowed to reach the Kubernetes API (step 3.2), as /32 CIDRs"
  type        = list(string)
}

variable "system_node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "system_node_count" {
  description = "Size of the fixed system node group. Karpenter adds everything else on demand."
  type        = object({ min = number, max = number, desired = number })
  default     = { min = 2, max = 3, desired = 2 }
}

variable "max_pods_per_node" {
  description = "Kubelet pod limit. 110 is the Kubernetes default and what prefix delegation supports on small instances."
  type        = number
  default     = 110
}

# ---- Database (Phase 5) ----
variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_engine_version" {
  type    = string
  default = "8.4"
}

variable "db_allocated_storage_gb" {
  type    = number
  default = 20
}

variable "db_multi_az" {
  description = "Standby in a second AZ. Doubles the cost; production: true."
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "true also keeps a final snapshot on destroy. Demo: false, so each session starts clean."
  type        = bool
  default     = false
}

# ---- Web Application Firewall (Phase 11) ----
variable "waf_rate_limit" {
  description = "Requests per IP per 5 minutes before WAF blocks that IP"
  type        = number
  default     = 600
}
```

### `envs/prod.tfvars`: this environment's values

```hcl
# Production settings for infra/platform. Used by: scripts/tf.sh platform <command>
environment        = "prod"
aws_region         = "us-east-1"
cluster_name       = "dkm"
domain_name        = "danielkojomegbenu.com"
kubernetes_version = "‹from 3.1, e.g. 1.37›"
# admin_cidrs (your IP) lives in envs/prod.local.tfvars, which git ignores. See step 3.2.

# Sizes. Everything below matches the defaults; it's listed so the cost drivers are in one place.
vpc_cidr                   = "10.0.0.0/16"
az_count                   = 3
single_nat_gateway         = true
system_node_instance_types = ["t3.medium"]
system_node_count          = { min = 2, max = 3, desired = 2 }
db_instance_class          = "db.t4g.micro"
db_allocated_storage_gb    = 20
db_multi_az                = false
db_deletion_protection     = false
```

### `envs/prod.backend.hcl`

```hcl
bucket       = "danielkojomegbenu-tfstate"
key          = "eks/platform-prod.tfstate"
region       = "us-east-1"
encrypt      = true
use_lockfile = true
```

### `envs/dev.tfvars` and `envs/dev.backend.hcl` (optional): proof the stack is reusable

A second, smaller cluster from the same code, with its own network range and its own state. You don't need to
create it: `ENV=dev scripts/tf.sh platform plan` shows what it would build (about 110 resources once Phases 5 and
11 are in) without touching prod.

```hcl
# Example second environment: a smaller, separate cluster with its own network range and state.
# Terraform side only. The gitops/ folder targets the prod cluster ("dkm"); a dev cluster would need its own
# Argo CD values (cluster name in the Karpenter settings, hostname) before it could run the app.
environment        = "dev"
aws_region         = "us-east-1"
cluster_name       = "dkm-dev"
domain_name        = "danielkojomegbenu.com"
kubernetes_version = "‹from 3.1, e.g. 1.37›"
# admin_cidrs (your IP) lives in envs/dev.local.tfvars, which git ignores. See step 3.2.

vpc_cidr                   = "10.1.0.0/16"
az_count                   = 2
system_node_instance_types = ["t3.small"]
system_node_count          = { min = 1, max = 2, desired = 2 }
```

```hcl
bucket       = "danielkojomegbenu-tfstate"
key          = "eks/platform-dev.tfstate"
region       = "us-east-1"
encrypt      = true
use_lockfile = true
```

### `vpc.tf`

```hcl
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs  = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  cidr = var.vpc_cidr
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.cluster_name
  cidr = local.cidr
  azs  = local.azs

  private_subnets  = [for i, _ in local.azs : cidrsubnet(local.cidr, 4, i)]      # /20 each (10.0.0.0/20 …): nodes and pods
  public_subnets   = [for i, _ in local.azs : cidrsubnet(local.cidr, 8, i + 48)] # /24 each (10.0.48.0/24 …): load balancers
  database_subnets = [for i, _ in local.azs : cidrsubnet(local.cidr, 8, i + 52)] # /24 each (10.0.52.0/24 …): RDS (Phase 5)

  create_database_subnet_group = true

  # One NAT gateway instead of one per AZ saves about $65/month (single_nat_gateway in envs/<env>.tfvars)
  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1 # the Load Balancer Controller puts internet-facing ALBs here
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = var.cluster_name # Karpenter launches nodes here
  }
}
```

### `eks.tf`

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.admin_cidrs

  # Gives the IAM identity running Terraform (your user) cluster-admin through an EKS access entry
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  addons = {
    vpc-cni = {
      before_compute = true
      # Prefix delegation: each network interface slot holds a /28 (16 IPs) instead of one IP, so a t3.medium can
      # run 110 pods instead of 17. Without it the system nodes filled up and DaemonSet pods couldn't start.
      configuration_values = jsonencode({
        env = { ENABLE_PREFIX_DELEGATION = "true", WARM_PREFIX_TARGET = "1" }
      })
    }
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    coredns                = {}
    aws-ebs-csi-driver     = {} # persistent volumes for Prometheus and Loki; its role is in pod-identity.tf
    metrics-server         = {} # kubectl top, and the Horizontal Pod Autoscaler
  }

  # Small fixed group for the cluster's own controllers (Argo CD, Karpenter, CoreDNS…).
  # Karpenter launches everything else on demand.
  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.system_node_instance_types
      min_size       = var.system_node_count.min
      max_size       = var.system_node_count.max
      desired_size   = var.system_node_count.desired
      labels = {
        "karpenter.sh/controller" = "true"
      }
      # Tell the kubelet about the higher pod limit that prefix delegation allows
      cloudinit_pre_nodeadm = [{
        content_type = "application/node.eks.aws"
        content      = <<-EOT
          apiVersion: node.eks.aws/v1alpha1
          kind: NodeConfig
          spec:
            kubelet:
              config:
                maxPods: ${var.max_pods_per_node}
        EOT
      }]
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}
```

> **If `terraform validate` rejects an argument name:** version 21 of this module renamed several inputs
> (`cluster_name` → `name`, `cluster_addons` → `addons` …). The module's
> [upgrade guide](https://github.com/terraform-aws-modules/terraform-aws-eks/tree/master/docs) lists them all.

### `karpenter.tf`

```hcl
# The AWS side of Karpenter: the IAM role its nodes use, the controller's permissions (via Pod Identity) and an
# SQS queue that receives spot interruption warnings. The controller itself is installed by Argo CD in Phase 4.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name
  namespace    = "kube-system"

  create_pod_identity_association = true

  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # shell access via SSM, no SSH keys
  }
}
```

### `pod-identity.tf`: one narrowly scoped role per add-on

```hcl
data "aws_route53_zone" "main" {
  name = var.domain_name
}

module "aws_lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                            = "${var.cluster_name}-aws-lb-controller"
  attach_aws_lb_controller_policy = true
  associations = {
    this = { cluster_name = module.eks.cluster_name, namespace = "kube-system", service_account = "aws-load-balancer-controller" }
  }
}

module "external_dns_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                          = "${var.cluster_name}-external-dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [data.aws_route53_zone.main.arn] # only this zone
  associations = {
    this = { cluster_name = module.eks.cluster_name, namespace = "external-dns", service_account = "external-dns" }
  }
}

module "external_secrets_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                           = "${var.cluster_name}-external-secrets"
  attach_external_secrets_policy = true
  # Only secrets under "<cluster_name>/" (the database connection, Phase 5). Nothing else in the account is readable.
  external_secrets_secrets_manager_arns = [
    "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.cluster_name}/*",
  ]
  associations = {
    this = { cluster_name = module.eks.cluster_name, namespace = "external-secrets", service_account = "external-secrets" }
  }
}

module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                      = "${var.cluster_name}-ebs-csi"
  attach_aws_ebs_csi_policy = true
  associations = {
    this = { cluster_name = module.eks.cluster_name, namespace = "kube-system", service_account = "ebs-csi-controller-sa" }
  }
}

# Used in Phase 9: Kyverno reads image signatures from ECR to verify them
module "kyverno_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${var.cluster_name}-kyverno"
  additional_policy_arns = {
    ecr_read = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  }
  associations = {
    this = { cluster_name = module.eks.cluster_name, namespace = "kyverno", service_account = "kyverno-admission-controller" }
  }
}
```

### `outputs.tf`

```hcl
output "cluster_name" {
  value = module.eks.cluster_name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "karpenter_node_role_name" {
  value = module.karpenter.node_iam_role_name
}

output "karpenter_queue_name" {
  value = module.karpenter.queue_name
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
```

---

## 3.4 💰 Create the cluster

```bash
terraform -chdir=infra/platform fmt -check -recursive
scripts/tf.sh platform validate
scripts/tf.sh platform plan -out=platform.tfplan
```

Expect roughly **110 resources to add** (the modules create many small pieces) and **0 to change or destroy**.
Check that the list includes `module.eks.aws_eks_cluster.this[0]`, one NAT gateway and the node group.

```bash
scripts/tf.sh platform apply platform.tfplan     # 15–20 minutes; the cluster itself takes about 10
rm infra/platform/platform.tfplan
$(scripts/tf.sh platform output -raw configure_kubectl)
```

---

## ✅ Phase 3 checkpoint

```bash
kubectl get nodes -o wide
# 2 nodes, STATUS Ready, ROLES <none>, in two different zones

kubectl get pods -A
# coredns, aws-node, kube-proxy, eks-pod-identity-agent, ebs-csi-*, metrics-server — all Running

kubectl top nodes                       # CPU and memory for both nodes (metrics-server works)

aws eks list-pod-identity-associations --cluster-name dkm --query 'associations[].[namespace,serviceAccount]' --output text
# 6 lines: aws-load-balancer-controller, external-dns, external-secrets, ebs-csi-controller-sa,
#          kyverno-admission-controller, karpenter

kubectl auth can-i '*' '*' --all-namespaces    # yes
```

### If something goes wrong

| Symptom | Fix |
|---|---|
| `kubectl` hangs or times out | Your IP changed. Update `admin_cidrs` in `envs/prod.local.tfvars`, then `scripts/tf.sh platform apply`. |
| `You must be logged in to the server (Unauthorized)` | The kubeconfig was made by a different AWS identity. Run `aws sts get-caller-identity`, then the `configure_kubectl` command again. |
| Apply fails on an add-on with `CREATE_FAILED … no nodes` | Rare timing issue. Run `scripts/tf.sh platform apply` again. |
| `metrics-server` add-on not found | Check that it's offered for your version: `aws eks describe-addon-versions --addon-name metrics-server --kubernetes-version ‹v›`. If not, remove it from `addons`; Phase 4 can install it with Argo CD. |

## Commit

```bash
git add infra/platform
git commit -m "Add platform stack: VPC, EKS, Karpenter and Pod Identity roles"
git push
```

---

> ### 🛑 End of session
> If you stop here, **destroy the platform stack** so it stops billing:
> ```bash
> scripts/tf.sh platform destroy     # about 10–15 minutes
> ```
> The foundation stack (ECR, certificate, CI role) stays. Next session, `scripts/tf.sh platform apply` brings everything
> back the same way. From Phase 4 on, destroying needs a few extra steps first, covered in each phase and in
> [Phase 12](12-portfolio-and-teardown.md#teardown).

**Next:** [Phase 4: GitOps bootstrap and add-ons](04-gitops-bootstrap.md)
