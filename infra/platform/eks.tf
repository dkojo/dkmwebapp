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
      instance_types = var.system_node_instance_types
      min_size       = var.system_node_count.min
      max_size       = var.system_node_count.max
      desired_size   = var.system_node_count.desired
      labels = {
        "karpenter.sh/controller" = "true"
      }
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}
