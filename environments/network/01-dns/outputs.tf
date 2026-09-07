output "apex_zone_id" {
  description = "Hosted zone ID of the apex zone"
  value       = aws_route53_zone.apex.zone_id
}

output "apex_name_servers" {
  description = "Name servers to register at the domain registrar"
  value       = aws_route53_zone.apex.name_servers
}

output "delegated_child_zones" {
  description = "Child zone FQDNs currently delegated from the apex zone"
  value       = sort(keys(var.child_zones))
}
