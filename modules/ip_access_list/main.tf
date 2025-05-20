resource "aws_security_group" "ip_access_list" {
  name        = var.name
  description = "IP Access List: ${var.name}"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.addresses
    content {
      from_port   = var.from_port
      to_port     = var.to_port
      protocol    = var.protocol
      cidr_blocks = [ingress.value.cidr]
      description = ingress.value.description
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
} 