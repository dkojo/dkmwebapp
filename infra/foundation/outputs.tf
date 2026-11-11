output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "ci_role_arn" {
  value     = aws_iam_role.ci.arn
  sensitive = true # contains the account ID; keep it out of logs
}

output "app_certificate_arn" {
  value     = aws_acm_certificate_validation.app.certificate_arn
  sensitive = true
}

output "route53_zone_id" {
  value = data.aws_route53_zone.main.zone_id
}
