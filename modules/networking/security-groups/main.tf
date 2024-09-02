resource "aws_security_group" "this" {
  name        = var.name
  description = var.description
  vpc_id      = var.vpc_id

  tags = merge(
    var.common_tags,
    {
      Name = var.name
    }
  )
}

# Create Ingress rules
resource "aws_security_group_rule" "ingress" {
  for_each = { for idx, rule in var.ingress_rules : idx => rule }

  type              = "ingress"
  security_group_id = aws_security_group.this.id

  description              = lookup(each.value, "description", null)
  from_port                = lookup(each.value, "from_port", 0)
  to_port                  = lookup(each.value, "to_port", 0)
  protocol                 = lookup(each.value, "protocol", "-1")
  cidr_blocks              = lookup(each.value, "cidr_blocks", null)
  source_security_group_id = lookup(each.value, "source_security_group_id", null)
}

# Create Egress rules
resource "aws_security_group_rule" "egress" {
  for_each = { for idx, rule in var.egress_rules : idx => rule }

  type              = "egress"
  security_group_id = aws_security_group.this.id

  description              = lookup(each.value, "description", null)
  from_port                = lookup(each.value, "from_port", 0)
  to_port                  = lookup(each.value, "to_port", 0)
  protocol                 = lookup(each.value, "protocol", "-1")
  cidr_blocks              = lookup(each.value, "cidr_blocks", null)
  source_security_group_id = lookup(each.value, "source_security_group_id", null)
}