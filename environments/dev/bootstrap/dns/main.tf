# dev account: child hosted zone dev.<root>. Its four name servers are registered in the
# network account apex zone (environments/network/01-dns var.child_zones).

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "Terraform"
    }
  }
}

resource "aws_route53_zone" "child" {
  name    = "${var.environment}.${var.root_domain}"
  comment = "${var.environment} child zone owned by the ${var.environment} account"

  tags = {
    Name        = "${var.environment}.${var.root_domain}"
    Environment = var.environment
    Layer       = "dns"
  }

  lifecycle {
    prevent_destroy = true
  }
}
