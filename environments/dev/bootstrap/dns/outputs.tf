output "zone_id" {
  description = "Child hosted zone ID → 03-platform hosted_zone_id"
  value       = aws_route53_zone.child.zone_id
}

output "zone_name" {
  description = "Child zone FQDN → 03-platform acm_domain_name and ExternalDNS domain filter"
  value       = aws_route53_zone.child.name
}

output "name_servers" {
  description = "Register these four in the apex zone child_zones map"
  value       = aws_route53_zone.child.name_servers
}
