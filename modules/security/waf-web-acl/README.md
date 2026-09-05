# Regional WAF and protected logs

Creates a REGIONAL Web ACL with default allow, AWS Common/KnownBadInputs/IPReputation managed groups, and a per-IP five-minute rate limit. The default limit is 2000; accepted values are integers from 10 to 100000. GitOps owns the ALB association and consumes `web_acl_arn`.

## Logging contract

The log name is `aws-waf-logs-${name}`. Include that exact name in the upstream log key's encryption contexts. `kms_key_arn` must be a same-account/same-Region key. Retention must be a supported finite CloudWatch value; prod requires at least 90 days.

A uniquely named resource policy permits only `delivery.logs.amazonaws.com` to create streams and write events in this group, conditioned on source account and the regional Logs source ARN. Logging configuration depends on this policy and the group.

Authorization, cookie, x-api-key, and query string fields are redacted. ACL and rule sampling are disabled because ordinary log redaction does not protect sampled requests. This is not a generic payload-sanitization system; applications must not put credentials in URI paths or custom unredacted fields.

## Verification and operations

Tests inspect real rendered provider resources and decoded delivery policy, including invalid retention, key Region, rate limits and provider identity. No live WAF association, rule behavior, or log receipt was executed. Managed-rule false positives and rate limits require controlled runtime testing before production traffic. Metrics remain enabled for monitoring.

The resource policy and logging configuration do not support tags in AWS provider 5.87.0. The taggable ACL and log group receive the four caller-supplied platform tags plus authoritative `ManagedBy=Terraform`.

References: [WAF CloudWatch logging](https://docs.aws.amazon.com/waf/latest/developerguide/logging-cw-logs.html), [delivery resource policy](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/AWS-logs-infrastructure-CWL.html), [provider 5.87 logging schema](https://github.com/hashicorp/terraform-provider-aws/blob/v5.87.0/website/docs/r/wafv2_web_acl_logging_configuration.html.markdown).
