locals {
  workload_state_objects = sort(tolist(local.terraform_state_object_arns))
}

variable "billing_monitor_role_arn" {
  description = "Optional exact externally managed read-only FinOps observer role for the trusted CI collector, never a management provisioning role."
  type        = string
  default     = null
  validation {
    condition     = var.billing_monitor_role_arn == null ? true : can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9_+=,.@/-]+$", var.billing_monitor_role_arn))
    error_message = "The billing observer must be one concrete IAM role ARN, without wildcards."
  }
}

variable "enterprise_resource_arns" {
  description = "Pre-approved exact regional resource ARNs, including planned resources. Empty sets grant no lifecycle permissions. Separate DB bootstrap/migration/backup/billing roles are not assumed."
  type        = object({ rds = set(string), secrets = set(string), kms = set(string), waf = set(string), sns = set(string) })
  default     = { rds = [], secrets = [], kms = [], waf = [], sns = [] }
  validation {
    condition     = alltrue(flatten([for service, arns in var.enterprise_resource_arns : [for a in arns : can(regex("^arn:aws:${service == "secrets" ? "secretsmanager" : service == "waf" ? "wafv2" : service}:${var.aws_region}:[0-9]{12}:[^*?]+$", a))]]))
    error_message = "Enterprise lifecycle grants require exact same-Region resource ARNs without wildcards."
  }
}
variable "enterprise_secret_names" {
  description = "Exact application/recovery/Argo secret shell names, without Secrets Manager's generated six-character suffix."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for n in var.enterprise_secret_names : can(regex("^[A-Za-z0-9/_+=.@-]+$", n))])
    error_message = "Secret shell names must be literal names without wildcards."
  }
}
variable "enterprise_waf_names" {
  description = "Exact planned regional WebACL names; the service generates the UUID."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for n in var.enterprise_waf_names : can(regex("^[A-Za-z0-9_-]{1,128}$", n))])
    error_message = "Use literal regional WebACL names."
  }
}

resource "aws_iam_policy" "enterprise" {
  name = "${var.infra_role_name}-enterprise"
  tags = local.common_tags
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(
    var.billing_monitor_role_arn == null ? [] : [{
      Sid      = "ExactReadOnlyBillingObserver"
      Effect   = "Allow"
      Action   = ["sts:AssumeRole"]
      Resource = [var.billing_monitor_role_arn]
    }],
    [{
      Sid       = "RegionalDiscovery"
      Effect    = "Allow"
      Action    = ["rds:DescribeDBInstances", "rds:DescribeDBSubnetGroups", "rds:DescribeDBParameterGroups", "rds:DescribeDBParameters", "rds:DescribeDBEngineVersions", "rds:DescribeOrderableDBInstanceOptions", "rds:DescribeCertificates", "rds:DescribeDBSnapshots", "rds:DescribeDBInstanceAutomatedBackups", "kms:ListAliases", "kms:ListKeys", "sns:ListTopics", "wafv2:ListWebACLs", "wafv2:ListResourcesForWebACL", "wafv2:ListLoggingConfigurations"]
      Resource  = "*"
      Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
    }],
    [{
      Sid       = "InventoryTaggedEnterpriseResources"
      Effect    = "Allow"
      Action    = ["tag:GetResources"]
      Resource  = "*"
      Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
      },
      {
        Sid       = "RdsAndWafServiceLinkedRoles"
        Effect    = "Allow"
        Action    = ["iam:CreateServiceLinkedRole"]
        Resource  = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/rds.amazonaws.com/AWSServiceRoleForRDS", "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/wafv2.amazonaws.com/AWSServiceRoleForWAFV2Logging"]
        Condition = { StringEquals = { "iam:AWSServiceName" = ["rds.amazonaws.com", "wafv2.amazonaws.com"] } }
    }],
    length(var.enterprise_resource_arns.rds) == 0 ? [] : [{
      Sid      = "ExactDatabaseLifecycle"
      Effect   = "Allow"
      Action   = ["rds:CreateDBInstance", "rds:ModifyDBInstance", "rds:DeleteDBInstance", "rds:RestoreDBInstanceToPointInTime", "rds:CreateDBSubnetGroup", "rds:ModifyDBSubnetGroup", "rds:DeleteDBSubnetGroup", "rds:CreateDBParameterGroup", "rds:ModifyDBParameterGroup", "rds:ResetDBParameterGroup", "rds:DeleteDBParameterGroup", "rds:CreateDBSnapshot", "rds:AddTagsToResource", "rds:RemoveTagsFromResource", "rds:ListTagsForResource"]
      Resource = sort(tolist(var.enterprise_resource_arns.rds))
    }],
    length(var.enterprise_resource_arns.secrets) == 0 ? [] : [{
      Sid      = "SecretShellMetadataOnly"
      Effect   = "Allow"
      Action   = ["secretsmanager:CreateSecret", "secretsmanager:DescribeSecret", "secretsmanager:DeleteSecret", "secretsmanager:RestoreSecret", "secretsmanager:TagResource", "secretsmanager:UntagResource", "secretsmanager:GetResourcePolicy", "secretsmanager:PutResourcePolicy", "secretsmanager:DeleteResourcePolicy"]
      Resource = sort(tolist(var.enterprise_resource_arns.secrets))
    }],
    length(var.enterprise_secret_names) == 0 ? [] : [{
      Sid      = "NamedSecretShells"
      Effect   = "Allow"
      Action   = ["secretsmanager:CreateSecret", "secretsmanager:DescribeSecret", "secretsmanager:DeleteSecret", "secretsmanager:RestoreSecret", "secretsmanager:TagResource", "secretsmanager:UntagResource", "secretsmanager:GetResourcePolicy"]
      Resource = [for n in sort(tolist(var.enterprise_secret_names)) : "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${n}-??????"]
    }],
    length(var.enterprise_resource_arns.rds) == 0 ? [] : [{
      Sid      = "RdsManagedSecretCreation"
      Effect   = "Allow"
      Action   = ["secretsmanager:CreateSecret", "secretsmanager:TagResource"]
      Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:rds!db-*"
    }],
    [{
      Sid       = "CreateOwnedLogKeys"
      Effect    = "Allow"
      Action    = ["kms:CreateKey"]
      Resource  = "*"
      Condition = { StringEquals = { "aws:RequestTag/PlatformInstanceId" = var.tags.PlatformInstanceId, "aws:RequestTag/ManagedBy" = "Terraform", "aws:RequestedRegion" = var.aws_region } }
    }],
    [{
      Sid      = "RegionalKeyMetadata"
      Effect   = "Allow"
      Action   = ["kms:DescribeKey"]
      Resource = "arn:aws:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:key/*"
    }],
    length(var.enterprise_resource_arns.kms) == 0 ? [] : [{
      Sid      = "ExactKeyAdministration"
      Effect   = "Allow"
      Action   = ["kms:DescribeKey", "kms:GetKeyPolicy", "kms:PutKeyPolicy", "kms:ListKeyPolicies", "kms:EnableKeyRotation", "kms:GetKeyRotationStatus", "kms:UpdateKeyDescription", "kms:TagResource", "kms:UntagResource", "kms:ListResourceTags", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion", "kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias"]
      Resource = sort(tolist(var.enterprise_resource_arns.kms))
    }],
    length(var.enterprise_resource_arns.kms) == 0 ? [] : [{
      Sid       = "RdsServiceGrantsOnExactKeys"
      Effect    = "Allow"
      Action    = ["kms:CreateGrant"]
      Resource  = sort(tolist(var.enterprise_resource_arns.kms))
      Condition = { Bool = { "kms:GrantIsForAWSResource" = "true" }, StringEquals = { "kms:ViaService" = "rds.${var.aws_region}.amazonaws.com" } }
    }],
    length(var.enterprise_resource_arns.waf) == 0 ? [] : [{
      Sid      = "ExactRegionalWaf"
      Effect   = "Allow"
      Action   = ["wafv2:CreateWebACL", "wafv2:GetWebACL", "wafv2:UpdateWebACL", "wafv2:DeleteWebACL", "wafv2:TagResource", "wafv2:UntagResource", "wafv2:ListTagsForResource", "wafv2:GetLoggingConfiguration", "wafv2:PutLoggingConfiguration", "wafv2:DeleteLoggingConfiguration"]
      Resource = sort(tolist(var.enterprise_resource_arns.waf))
    }],
    length(var.enterprise_waf_names) == 0 ? [] : [{
      Sid      = "NamedRegionalWebAcl"
      Effect   = "Allow"
      Action   = ["wafv2:CreateWebACL", "wafv2:GetWebACL", "wafv2:UpdateWebACL", "wafv2:DeleteWebACL", "wafv2:TagResource", "wafv2:UntagResource", "wafv2:ListTagsForResource", "wafv2:GetLoggingConfiguration", "wafv2:PutLoggingConfiguration", "wafv2:DeleteLoggingConfiguration"]
      Resource = [for n in sort(tolist(var.enterprise_waf_names)) : "arn:aws:wafv2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:regional/webacl/${n}/*"]
    }],
    length(var.enterprise_resource_arns.sns) == 0 ? [] : [{
      Sid      = "ExactAmpAlertTopic"
      Effect   = "Allow"
      Action   = ["sns:CreateTopic", "sns:GetTopicAttributes", "sns:SetTopicAttributes", "sns:DeleteTopic", "sns:TagResource", "sns:UntagResource", "sns:ListTagsForResource", "sns:Subscribe", "sns:Unsubscribe", "sns:GetSubscriptionAttributes", "sns:SetSubscriptionAttributes", "sns:ListSubscriptionsByTopic"]
      Resource = sort(tolist(var.enterprise_resource_arns.sns))
    }]
  ) })
  lifecycle {
    precondition {
      condition     = alltrue(flatten([for arns in var.enterprise_resource_arns : [for a in arns : split(":", a)[4] == data.aws_caller_identity.current.account_id]]))
      error_message = "Do not authorize another account's billing SNS, database or key through workload OIDC."
    }
  }
}
resource "aws_iam_role_policy_attachment" "enterprise" {
  role       = aws_iam_role.infra.name
  policy_arn = aws_iam_policy.enterprise.arn
}
