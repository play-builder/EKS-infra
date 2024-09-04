
output "map_users" {
  description = "List of 'mapUsers' objects for aws-auth"
  value       = local.map_users
}

output "map_roles" {
  description = "List of 'mapRoles' objects for aws-auth"
  value       = local.map_roles
}