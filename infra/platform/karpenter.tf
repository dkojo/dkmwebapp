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
