# Production settings for infra/foundation. Used by: scripts/tf.sh foundation <command>
aws_region                 = "us-east-1"
app_name                   = "dkmwebapp"
name_prefix                = "eks-dkm"
github_repo                = "dkojo/dkmwebapp"
github_oidc_subject_prefix = "repo:dkojo@167027053/dkmwebapp@893369381" # immutable form, from Phase 0.5
ci_branches                = ["remodelled"]
domain_name                = "danielkojomegbenu.com"
app_hostname               = "app.danielkojomegbenu.com"
