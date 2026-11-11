# Phase 3: EKS cluster

**Goal:** a VPC across three availability zones, an EKS cluster with two small system nodes, the AWS
resources Karpenter needs, and Pod Identity roles for every add-on, all in the `platform` stack that you create
and destroy each session.

**Time:** about 2 hours (Terraform itself runs 15–20 minutes) · **💰 Cost while running: about $0.25/hour**

---

## 3.1 Pick the Kubernetes version

```bash
aws eks describe-cluster-versions --query "clusterVersions[?versionStatus=='STANDARD_SUPPORT'].clusterVersion" --output text
# e.g. 1.33  1.34  1.35  → use the newest one
```

⚠️ Avoid versions in **extended support**. They cost **$0.60/hour** instead of $0.10.

## 3.2 Find your public IP

The cluster's API endpoint will only accept connections from your IP:

```bash
curl -s https://checkip.amazonaws.com    # e.g. 203.0.113.25
```

If your home IP changes later, `kubectl` will time out. Update `admin_cidrs` and run `terraform apply` again.

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
  backend "s3" {
    bucket       = "danielkojomegbenu-tfstate"
    key          = "eks/platform.tfstate"
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
      Stack     = "platform"
      ManagedBy = "terraform"
      Repo      = "dkojo/dkmwebapp"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
```

### `variables.tf`

```hcl
variable "cluster_name" {
  type    = string
  default = "dkm"
}

variable "kubernetes_version" {
  description = "Newest version in standard support (step 3.1)"
  type        = string
}

variable "admin_cidrs" {
  description = "IPs allowed to reach the Kubernetes API (step 3.2), as /32 CIDRs"
  type        = list(string)
}

variable "domain_name" {
  type    = string
  default = "danielkojomegbenu.com"
}
```

### `terraform.tfvars`

```hcl
kubernetes_version = "‹from 3.1, e.g. 1.35›"
admin_cidrs        = ["‹your IP›/32"]
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
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)
  cidr = "10.0.0.0/16"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.cluster_name
  cidr = local.cidr
  azs  = local.azs

  private_subnets  = [for i, _ in local.azs : cidrsubnet(local.cidr, 4, i)]      # 10.0.0.0/20 … nodes and pods
  public_subnets   = [for i, _ in local.azs : cidrsubnet(local.cidr, 8, i + 48)] # 10.0.48.0/24 … load balancers
  database_subnets = [for i, _ in local.azs : cidrsubnet(local.cidr, 8, i + 52)] # 10.0.52.0/24 … RDS (Phase 5)

  create_database_subnet_group = true

  # One NAT gateway instead of three: about $65/month cheaper. Production would use one per AZ.
  enable_nat_gateway = true
  single_nat_gateway = true

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
    vpc-cni                = { before_compute = true }
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
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      labels = {
        "karpenter.sh/controller" = "true"
      }
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
  # Only secrets under "dkm/" (the database connection, Phase 5). Nothing else in the account is readable.
  external_secrets_secrets_manager_arns = [
    "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:dkm/*",
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
  value = "aws eks update-kubeconfig --region us-east-1 --name ${module.eks.cluster_name}"
}
```

---

## 3.4 💰 Create the cluster

```bash
cd infra/platform
terraform init
terraform fmt -check && terraform validate
terraform plan -out=platform.tfplan
```

Expect roughly **80–100 resources to add** (the modules create many small pieces) and **0 to change or destroy**.
Check that the list includes `module.eks.aws_eks_cluster.this[0]`, one NAT gateway and the node group.

```bash
terraform apply platform.tfplan     # 15–20 minutes; the cluster itself takes about 10
rm platform.tfplan
$(terraform output -raw configure_kubectl)
cd ../..
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
| `kubectl` hangs or times out | Your IP changed. Update `admin_cidrs`, then `terraform apply`. |
| `You must be logged in to the server (Unauthorized)` | The kubeconfig was made by a different AWS identity. Run `aws sts get-caller-identity`, then the `configure_kubectl` command again. |
| Apply fails on an add-on with `CREATE_FAILED … no nodes` | Rare timing issue. Run `terraform apply` again. |
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
> terraform -chdir=infra/platform destroy     # about 10–15 minutes
> ```
> The foundation stack (ECR, certificate, CI role) stays. Next session, `terraform apply` brings everything
> back the same way. From Phase 4 on, destroying needs a few extra steps first, covered in each phase and in
> [Phase 12](12-portfolio-and-teardown.md#teardown).

**Next:** [Phase 4: GitOps bootstrap and add-ons](04-gitops-bootstrap.md)
