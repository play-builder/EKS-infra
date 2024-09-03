output "iam_role_arn" {
  description = "ARN of the IAM role"
  value       = aws_iam_role.this.arn
}

# ▼▼▼ [추가] 이 부분이 누락되어 에러가 났습니다. 반드시 추가해주세요! ▼▼▼
output "iam_role_name" {
  description = "Name of the IAM role"
  value       = aws_iam_role.this.name
}

