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
