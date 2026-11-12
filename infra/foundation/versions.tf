terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial backend: the bucket, key and region come from envs/<env>.backend.hcl at init time
  # (scripts/tf.sh does this), so the same code can keep separate state per environment or account.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project   = var.app_name
      Stack     = "foundation"
      ManagedBy = "terraform"
      Repo      = var.github_repo
    }
  }
}
