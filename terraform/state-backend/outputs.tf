output "bucket_name" {
  description = "Terraform state bucket name."
  value       = aws_s3_bucket.terraform_state.id
}

output "bucket_arn" {
  description = "Terraform state bucket ARN."
  value       = aws_s3_bucket.terraform_state.arn
}

output "bucket_region" {
  description = "Terraform state bucket Region."
  value       = aws_s3_bucket.terraform_state.region
}
