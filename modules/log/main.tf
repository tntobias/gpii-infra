resource "aws_cloudwatch_log_group" "main" {
  name = "${var.cluster_name}"

# The logs shouldn't be removed between deployments, but we have to set the
# scope in terraform to avoid issues at the 'detroy' step.
#  lifecycle {
#    prevent_destroy = true
#  }

  tags {
    Environment = "${var.cluster_name}"
    Terraform = true
  }
}
