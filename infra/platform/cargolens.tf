# CargoLens (github.com/dkojo/cargolens), a second tenant on this platform: the customs risk-ranking
# proof of concept from the dissertation, deployed by Argo CD from its own repository (gitops/apps/cargolens.yaml).
#
# Created per session, like everything in this stack, and only when cargolens_bundle_uri is set (in the
# git-ignored envs/<env>.local.tfvars). Without it the platform runs exactly as before.
#
#   PostgreSQL (RDS)    the app's database; reloaded from the data bundle each session
#   Secrets Manager     dkm/cargolens: database, signing key, bundle location, demo passwords (External Secrets)
#   Pod Identity        read-only access to the bundle archive in CargoLens's private S3 bucket, nothing else
#   AWS WAF             its own ALB and Web ACL: approved IPs only, then the same managed rules as dkmwebapp

locals {
  cargolens        = var.cargolens_bundle_uri != ""
  cargolens_bucket = split("/", trimprefix(var.cargolens_bundle_uri, "s3://"))[0]
  cargolens_users  = toset(["officer", "officer2", "supervisor", "auditor"])
}

resource "aws_security_group" "cargolens_db" {
  count       = local.cargolens ? 1 : 0
  name        = "${var.cluster_name}-cargolens-db"
  description = "PostgreSQL from EKS nodes only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL from cluster nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
}

resource "random_password" "cargolens_db" {
  count   = local.cargolens ? 1 : 0
  length  = 32
  special = false # goes into a database URL: letters and digits need no escaping
}

resource "random_password" "cargolens_app_secret" {
  count   = local.cargolens ? 1 : 0
  length  = 48
  special = false
}

resource "random_password" "cargolens_demo" {
  for_each = local.cargolens ? local.cargolens_users : toset([])
  length   = 16
  special  = false
}

resource "aws_db_instance" "cargolens" {
  count          = local.cargolens ? 1 : 0
  identifier     = "${var.cluster_name}-cargolens"
  engine         = "postgres"
  engine_version = var.cargolens_db_engine_version
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "cargolens"
  username = "cargolens"
  password = random_password.cargolens_db[0].result

  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.cargolens_db[0].id]
  publicly_accessible    = false

  multi_az                = false
  backup_retention_period = 1
  # Demo: no final snapshot, because the load Job refills the database from the bundle every session
  deletion_protection = false
  skip_final_snapshot = true
  apply_immediately   = true
}

resource "aws_secretsmanager_secret" "cargolens" {
  count                   = local.cargolens ? 1 : 0
  name                    = "${var.cluster_name}/cargolens" # External Secrets may read dkm/* only
  description             = "CargoLens database, signing key, bundle location and demo passwords"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "cargolens" {
  count     = local.cargolens ? 1 : 0
  secret_id = aws_secretsmanager_secret.cargolens[0].id
  secret_string = jsonencode({
    host       = aws_db_instance.cargolens[0].address
    port       = tostring(aws_db_instance.cargolens[0].port)
    dbname     = aws_db_instance.cargolens[0].db_name
    username   = aws_db_instance.cargolens[0].username
    password   = random_password.cargolens_db[0].result
    app_secret = random_password.cargolens_app_secret[0].result
    bundle_uri = var.cargolens_bundle_uri
    # The loader passes this as S3's ExpectedBucketOwner: a same-named bucket in another account is refused
    bundle_bucket_owner = data.aws_caller_identity.current.account_id
    demo_passwords      = jsonencode({ for u in local.cargolens_users : u => random_password.cargolens_demo[u].result })
  })
}

# Pod Identity for the cargolens service account: read the bundle archives, nothing else
resource "aws_iam_role" "cargolens" {
  count = local.cargolens ? 1 : 0
  name  = "${var.cluster_name}-cargolens"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "cargolens_bundle" {
  count = local.cargolens ? 1 : 0
  name  = "read-bundle"
  role  = aws_iam_role.cargolens[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = ["arn:aws:s3:::${local.cargolens_bucket}/bundles/*"]
    }]
  })
}

resource "aws_eks_pod_identity_association" "cargolens" {
  count           = local.cargolens ? 1 : 0
  cluster_name    = module.eks.cluster_name
  namespace       = "cargolens"
  service_account = "cargolens"
  role_arn        = aws_iam_role.cargolens[0].arn
}

# CargoLens stays restricted to approved networks, as on its EC2 demo: requests from any other IP are blocked
# before the managed rules run. The IPs come from admin_cidrs and cargolens_allowed_cidrs (local tfvars).
resource "aws_wafv2_ip_set" "cargolens" {
  count              = local.cargolens ? 1 : 0
  name               = "${var.cluster_name}-cargolens-approved"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = concat(var.admin_cidrs, var.cargolens_allowed_cidrs)
}

resource "aws_wafv2_web_acl" "cargolens" {
  count = local.cargolens ? 1 : 0
  name  = "${var.cluster_name}-cargolens" # the Ingress refers to it by this name
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "approved-ips-only"
    priority = 0
    action {
      block {}
    }
    statement {
      not_statement {
        statement {
          ip_set_reference_statement {
            arn = aws_wafv2_ip_set.cargolens[0].arn
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "cargolens-approved-ips-only"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = {
      AWSManagedRulesCommonRuleSet          = 10
      AWSManagedRulesKnownBadInputsRuleSet  = 20
      AWSManagedRulesSQLiRuleSet            = 30
      AWSManagedRulesAmazonIpReputationList = 40
    }
    content {
      name     = rule.key
      priority = rule.value
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "cargolens-${rule.key}"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 50
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 600 # per IP per 5 minutes
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "cargolens-rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.cluster_name}-cargolens"
    sampled_requests_enabled   = true
  }
}
