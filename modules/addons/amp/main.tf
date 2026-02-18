resource "aws_prometheus_workspace" "this" {
  alias = var.name

  logging_configuration {
    log_group_arn = "${aws_cloudwatch_log_group.amp.arn}:*"
  }

  tags = merge(
    var.tags,
    {
      Name = var.name
    }
  )
}

resource "aws_cloudwatch_log_group" "amp" {
  name              = "/aws/amp/${var.name}"
  retention_in_days = 7

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-amp-logs"
    }
  )
}