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

output "cargolens_credentials_command" {
  description = "Prints the CargoLens demo passwords (only when CargoLens is deployed)"
  value       = local.cargolens ? "aws secretsmanager get-secret-value --region ${var.aws_region} --secret-id ${var.cluster_name}/cargolens --query SecretString --output text | jq -r .demo_passwords" : null
}
