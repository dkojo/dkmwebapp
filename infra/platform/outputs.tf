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
