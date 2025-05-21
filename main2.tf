provider "aws" {
  region = "us-east-1"
}

# ----------- Inputs -------------
variable "ami_id" {}
variable "name" { default = "eventstore-single" }
variable "subnet_id" {}
variable "vpc_id" {}
variable "availability_zone" {}
variable "key_name" {}

# Optional
variable "instance_type"     { default = "t3.medium" }
variable "allowed_cidrs"     { default = ["10.0.0.0/16"] }
variable "associate_public_ip" { default = false }
variable "volume_size"       { default = 20 }
variable "volume_type"       { default = "gp3" }
variable "force_bootstrap"   { default = false }
variable "tags"              { default = {} }

# ----------- IAM -------------
resource "aws_iam_role" "instance" {
  name = "${var.name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "inline" {
  name = "${var.name}-custom"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "ssm:GetParameter",
          "ssm:GetParametersByPath"
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-profile"
  role = aws_iam_role.instance.name
}

# ----------- Security Group -------------
resource "aws_security_group" "this" {
  name        = "${var.name}-sg"
  vpc_id      = var.vpc_id
  description = "EventStore ports"

  ingress {
    from_port   = 2113
    to_port     = 2113
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

# ----------- Instance -------------
resource "aws_instance" "this" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  availability_zone           = var.availability_zone
  associate_public_ip_address = var.associate_public_ip
  key_name                    = var.key_name

  iam_instance_profile   = aws_iam_instance_profile.this.name
  vpc_security_group_ids = [aws_security_group.this.id]

  user_data = var.force_bootstrap ? <<-EOT
              #!/bin/bash
              touch /etc/eventstore/force_bootstrap
              reboot
    EOT : null

  tags = merge({
    Name = var.name
  }, var.tags)
}

# ----------- Volume -------------
resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.volume_size
  type              = var.volume_type
  encrypted         = true
  tags = {
    Name    = "${var.name}-data"
    Service = "eventstore"
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.this.id
}

# ----------- Optional SSM Params (example only) -------------
resource "aws_ssm_parameter" "gossip_mode" {
  name  = "/eventstore/config/gossip_mode"
  type  = "String"
  value = "ip"
}

resource "aws_ssm_parameter" "cert_pem" {
  name  = "/eventstore/ssl/pem"
  type  = "SecureString"
  value = base64encode(file("cert.pem"))
}
