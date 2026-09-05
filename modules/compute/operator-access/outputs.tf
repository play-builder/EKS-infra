output "operator_access_status" {
  value = {
    mode                      = var.mode
    private_instance_id       = aws_instance.operator.id
    operator_role_arn         = var.operator_role_arn
    private_endpoint_required = true
  }
}

output "operator_instance_id" { value = aws_instance.operator.id }
