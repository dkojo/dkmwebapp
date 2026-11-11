terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Same state bucket as the portfolio, different key. S3 native locking, no DynamoDB.
  backend "s3" {
    bucket       = "danielkojomegbenu-tfstate"
    key          = "eks/foundation.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project   = "dkmwebapp"
      Stack     = "foundation"
      ManagedBy = "terraform"
      Repo      = "dkojo/dkmwebapp"
    }
  }
}
