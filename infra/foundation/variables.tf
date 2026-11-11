variable "app_name" {
  type    = string
  default = "dkmwebapp"
}

variable "domain_name" {
  description = "Existing Route 53 zone (created by the portfolio repo)"
  type        = string
  default     = "danielkojomegbenu.com"
}

variable "app_hostname" {
  type    = string
  default = "app.danielkojomegbenu.com"
}

variable "github_oidc_subject_prefix" {
  description = "From Phase 0.5: gh api repos/dkojo/dkmwebapp/actions/oidc/customization/sub"
  type        = string
}
