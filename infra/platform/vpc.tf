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
