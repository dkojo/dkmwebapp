resource "aws_wafv2_web_acl" "dkm" {
  name  = "${var.cluster_name}-alb" # the Ingress refers to it by name, which stays the same every session
  scope = "REGIONAL"                # REGIONAL = for ALBs; CLOUDFRONT would be for distributions

  default_action {
    allow {}
  }

  # AWS-managed rule groups: no rules to write or maintain yourself
  dynamic "rule" {
    for_each = {
      AWSManagedRulesCommonRuleSet          = 10 # OWASP-style: XSS, path traversal, bad bots…
      AWSManagedRulesKnownBadInputsRuleSet  = 20 # Log4Shell and similar exploit payloads
      AWSManagedRulesSQLiRuleSet            = 30 # SQL injection
      AWSManagedRulesAmazonIpReputationList = 40 # IPs AWS has seen attacking
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
        metric_name                = rule.key
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
        limit              = var.waf_rate_limit # per IP per 5 minutes; prod sets 3000 because the load generator (one NAT IP) sends ~1,000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.cluster_name}-alb"
    sampled_requests_enabled   = true
  }
}
