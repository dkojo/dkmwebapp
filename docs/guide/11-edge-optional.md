# Phase 11 (optional): Web Application Firewall

**Goal:** AWS WAF in front of `dkmwebapp`, blocking common attacks (SQL injection, known-bad inputs, abusive IPs)
and rate-limiting any single IP.

**Time:** about 1 hour · **💰 Cost:** about $5/month per web ACL + $1/month per rule + $0.60 per million
requests, **prorated hourly**. Because it lives in the platform stack, you pay only while sessions run:
roughly $0.01/hour.

---

## 11.1 WAF on the ALB vs CloudFront + WAF

Your portfolio diagram shows **CloudFront + WAF** in front of the load balancer. For this project, attaching
WAF **directly to the ALB** gives the same protection with fewer moving parts:

| | WAF on the ALB (this phase) | CloudFront + WAF |
|---|---|---|
| Attack filtering, rate limiting | ✅ | ✅ |
| Edge caching, lower latency worldwide | ❌ | ✅ |
| Extra setup | One Terraform file, one annotation | A second hostname for the ALB origin, a CloudFront distribution, a certificate in the same region, and making sure users can't bypass CloudFront |
| Fits "create and destroy per session" | ✅ | Slow: CloudFront takes 5–15 min to create and to delete |

An API like `dkmwebapp` gains little from edge caching, so this phase uses WAF on the ALB. If you build this
version, Phase 12 shows how to relabel the diagram box so it matches what you built. CloudFront + WAF is a
good **"next steps"** item for the README.

---

## 11.2 Terraform: `infra/platform/waf.tf`

```hcl
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
```

⚠️ **The load generator from Phase 10 would trip the default limit (600):** it sends about 1,000 requests per
5 minutes, all from the NAT gateway's single IP. This project sets it in `envs/prod.tfvars`:

```hcl
waf_rate_limit             = 3000 # the Phase 10 load generator sends ~1,000 per 5 min from the NAT gateway IP
```

A rate limit that a single real client at 3 requests a second can't reach is still useful against floods. The
alternative is an IP set rule that exempts the NAT IP, which is one more thing to keep in sync each session.

Review the plan before applying: it must only add.

```bash
scripts/tf.sh platform plan -out=waf.tfplan     # expect: Plan: 1 to add, 0 to change, 0 to destroy
scripts/tf.sh platform apply waf.tfplan
aws wafv2 list-web-acls --scope REGIONAL --query "WebACLs[].Name"    # ["dkm-alb"]
```

CI only scans infrastructure code when `app/` changes, so scan the new file yourself:
`trivy config --severity HIGH,CRITICAL --skip-dirs infra/platform/.terraform --ignorefile .trivyignore infra/platform`.

## 11.3 Attach it to the ALB

Make the web ACL a chart value, so another environment (whose ACL is `<cluster>-alb`) can set its own, or none.
In `gitops/charts/dkmwebapp/values.yaml`, under `ingress:`:

```yaml
  wafAclName: ""          # Phase 11: the AWS WAF web ACL to attach (infra/platform/waf.tf names it <cluster>-alb)
```

In `templates/ingress.yaml`, after the `group.name` annotation:

```yaml
    {{- with .Values.ingress.wafAclName }}
    alb.ingress.kubernetes.io/wafv2-acl-name: {{ . }}         # Phase 11: AWS WAF in front of the ALB
    {{- end }}
```

And in `gitops/envs/prod/values.yaml`:

```yaml
ingress:
  wafAclName: dkm-alb    # Phase 11: managed rules + per-IP rate limit (infra/platform/waf.tf)
```

```bash
git add gitops && git commit -m "Protect dkmwebapp with AWS WAF managed rules and per-IP rate limiting" && git push
```

---

## ✅ Phase 11 checkpoint

```bash
aws wafv2 list-resources-for-web-acl --resource-type APPLICATION_LOAD_BALANCER \
  --web-acl-arn "$(aws wafv2 list-web-acls --scope REGIONAL --query "WebACLs[?Name=='dkm-alb'].ARN" --output text)"
# one ALB ARN (k8s-dkm-…)

curl -s -o /dev/null -w '%{http_code}\n' "https://app.danielkojomegbenu.com/api/products?id=1%27%20OR%20%271%27=%271"
# 403: the SQL injection rule blocked it

curl -s -o /dev/null -w '%{http_code}\n' https://app.danielkojomegbenu.com/api/products
# 200: normal traffic still passes
```

The first run: the association appeared about 10 seconds after Argo CD synced. Every attack below got **403**,
normal requests 200, and the load generator was never rate-limited:

| Request | Result | Rule group |
|---|---|---|
| `?id=1' OR '1'='1` | 403 | SQLi |
| `?q=1 UNION SELECT password FROM users` | 403 | SQLi |
| `?q=<script>alert(1)</script>` | 403 | Common (XSS) |
| `?file=../../../../etc/passwd` | 403 | Common (path traversal) |
| header `X-Api-Version: ${jndi:ldap://…}` | 403 | Known bad inputs (Log4Shell) |

In the console, **WAF & Shield → Web ACLs → dkm-alb → Overview**, you'll see the blocked request in
"Sampled requests". That's a good screenshot.

> ### 🛑 End of session
> Nothing extra: the web ACL is in the platform stack, so `terraform destroy` removes it. Its association goes
> when the ALB does.

**Next:** [Phase 12: Portfolio, documentation and teardown](12-portfolio-and-teardown.md)
