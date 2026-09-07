# network account: apex hosted zone for the platform domain and NS delegation records
# for the per-environment child zones (dev.<root>, prod.<root>).
# Child zones are created in the dev/prod accounts; their name servers are passed in
# through var.child_zones so this root stays the only writer of the apex zone.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "Terraform"
    }
  }
}

resource "aws_route53_zone" "apex" {
  name    = var.root_domain
  comment = "Apex zone owned by the network account"

  tags = {
    Name        = var.root_domain
    Environment = "network"
    Layer       = "dns"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_route53_record" "child_delegation" {
  for_each = var.child_zones

  zone_id = aws_route53_zone.apex.zone_id
  name    = each.key
  type    = "NS"
  ttl     = 300
  records = each.value
}
