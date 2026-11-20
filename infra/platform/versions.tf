terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  # Partial backend: bucket, key and region come from envs/<env>.backend.hcl (scripts/tf.sh passes it)
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.app_name
      Environment = var.environment
      Stack       = "platform"
      ManagedBy   = "terraform"
      Repo        = var.github_repo
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
