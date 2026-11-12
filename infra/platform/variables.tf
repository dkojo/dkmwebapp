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
