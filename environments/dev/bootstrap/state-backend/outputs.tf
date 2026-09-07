output "bucket_name" {
  value = module.state_backend.bucket_name
}

output "bucket_arn" {
  value = module.state_backend.bucket_arn
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
