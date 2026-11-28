data "aws_route53_zone" "main" {
  name = var.domain_name
}

resource "aws_acm_certificate" "app" {
  domain_name       = var.app_hostname
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "app_cert_validation" {
  for_each = {
    for o in aws_acm_certificate.app.domain_validation_options : o.domain_name => o
  }
  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 300
}

resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in aws_route53_record.app_cert_validation : r.fqdn]
}

# Certificates for other apps hosted on the platform (CargoLens). Kept here, not per session, so a session
# never waits for DNS validation. The ALB controller finds each one by hostname, like the app's.
resource "aws_acm_certificate" "hosted" {
  for_each          = toset(var.hosted_app_hostnames)
  domain_name       = each.value
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "hosted_cert_validation" {
  for_each = {
    for o in flatten([for c in aws_acm_certificate.hosted : tolist(c.domain_validation_options)]) : o.domain_name => o
  }
  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 300
}

resource "aws_acm_certificate_validation" "hosted" {
  for_each                = aws_acm_certificate.hosted
  certificate_arn         = each.value.arn
  validation_record_fqdns = [aws_route53_record.hosted_cert_validation[each.key].fqdn]
}
