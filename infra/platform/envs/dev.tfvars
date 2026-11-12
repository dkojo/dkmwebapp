# Example second environment: a smaller, separate cluster with its own network range and state.
# Terraform side only. The gitops/ folder targets the prod cluster ("dkm"); a dev cluster would need its own
# Argo CD values (cluster name in the Karpenter settings, hostname) before it could run the app.
environment        = "dev"
aws_region         = "us-east-1"
cluster_name       = "dkm-dev"
domain_name        = "danielkojomegbenu.com"
kubernetes_version = "1.37"
# admin_cidrs (your IP) lives in envs/dev.local.tfvars, which git ignores. See step 3.2.

vpc_cidr                   = "10.1.0.0/16"
az_count                   = 2
system_node_instance_types = ["t3.small"]
system_node_count          = { min = 1, max = 2, desired = 2 }
