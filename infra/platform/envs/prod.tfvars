# Production settings for infra/platform. Used by: scripts/tf.sh platform <command>
environment        = "prod"
aws_region         = "us-east-1"
cluster_name       = "dkm"
domain_name        = "danielkojomegbenu.com"
kubernetes_version = "1.37"
# admin_cidrs (your IP) lives in envs/prod.local.tfvars, which git ignores. See step 3.2.

# Sizes. Everything below matches the defaults; it's listed so the cost drivers are in one place.
vpc_cidr                   = "10.0.0.0/16"
az_count                   = 3
single_nat_gateway         = true
system_node_instance_types = ["t3.medium"]
system_node_count          = { min = 3, max = 4, desired = 3 }
db_instance_class          = "db.t4g.micro"
db_allocated_storage_gb    = 20
db_multi_az                = false
db_deletion_protection     = false
waf_rate_limit             = 3000 # the Phase 10 load generator sends ~1,000 per 5 min from the NAT gateway IP
