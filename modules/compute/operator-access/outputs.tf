output "operator_access_status" {
  description = "Private SSM operator instance and the customer-managed EKS operator role binding"
  value = {
    mode                      = var.mode
    private_instance_id       = aws_instance.operator.id
    operator_role_arn         = aws_iam_role.operator.arn
    private_endpoint_required = true
  }
}

output "operator_instance_id" {
  description = "Private EC2 instance ID used only through AWS Systems Manager"
  value       = aws_instance.operator.id
}

output "operator_role_arn" {
  description = "Customer-managed IAM role authorized by the EKS Access Entry"
  value       = aws_iam_role.operator.arn
}
