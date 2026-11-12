variable "aws_region" {
  description = "Region for every resource in this stack"
  type        = string
  default     = "us-east-1"
}

variable "app_name" {
  description = "Names the ECR repository and the Project tag"
  type        = string
  default     = "dkmwebapp"
}

variable "name_prefix" {
  description = "Prefix for IAM names, e.g. eks-dkm gives the role eks-dkm-ci"
  type        = string
  default     = "eks-dkm"
}

variable "github_repo" {
  description = "owner/name of the repository whose workflows build the app"
  type        = string
}

variable "github_oidc_subject_prefix" {
  description = "From Phase 0.5: gh api repos/<owner>/<repo>/actions/oidc/customization/sub"
  type        = string
}

variable "ci_branches" {
  description = "Branches whose workflow runs may push images. Pull requests never get AWS access."
  type        = list(string)
  default     = ["remodelled"]
}

variable "domain_name" {
  description = "Existing Route 53 public zone the certificate is validated in"
  type        = string
}

variable "app_hostname" {
  description = "Hostname the certificate covers"
  type        = string
}

variable "ecr_keep_images" {
  description = "How many recent images ECR keeps"
  type        = number
  default     = 50
}

variable "ecr_untagged_expiry_days" {
  description = "Days before untagged layers are deleted"
  type        = number
  default     = 14
}
