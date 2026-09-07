output "bucket_name" {
  description = "State bucket name to pass to terraform init -backend-config=bucket="
  value       = aws_s3_bucket.terraform_state.bucket
}

output "bucket_arn" {
  description = "State bucket ARN for IAM policies"
  value       = aws_s3_bucket.terraform_state.arn
}

output "bucket_region" {
  description = "Region of the state bucket"
  value       = aws_s3_bucket.terraform_state.region
}
