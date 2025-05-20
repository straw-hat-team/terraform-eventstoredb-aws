terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "6.0.0-beta1"
    }
  }
}

provider "aws" {}

variable "network_type" {
  description = "Specify if the instance should be public or private"
  type        = string
  default     = "private"
}

variable "key_pair_name" {}

variable "cluster_size" {
  description = "Number of nodes in the EventStoreDB cluster (must be odd)"
  type        = number
  default     = 3
}

variable "gossip_mode" {
  description = "Choose 'ip' or 'dns' for gossip seed discovery"
  type        = string
  default     = "ip"
}

variable "ami_id" {
  description = "Optional: Specific AMI ID to use. If not provided, will use latest Ubuntu 22.04 LTS"
  type        = string
  default     = null
}

variable "availability_zone" {
  description = "Optional: Specific availability zone to use. If not provided, will use first available AZ"
  type        = string
  default     = null
}

variable "bastion_ips" {
  description = "List of CIDR blocks for bastion hosts that need access to EventStoreDB admin interface"
  type        = list(string)
  default     = []
}

# Get available AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# Get latest Ubuntu 22.04 LTS AMI if not specified
data "aws_ami" "ubuntu" {
  count       = var.ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id = var.ami_id != null ? var.ami_id : data.aws_ami.ubuntu[0].id
  az     = var.availability_zone != null ? var.availability_zone : data.aws_availability_zones.available.names[0]
}

# Fetch EventStoreDB config and certs from SSM

data "aws_ssm_parameter" "eventstore_conf" {
  name            = "/eventstore/config"
  with_decryption = true
}

data "aws_ssm_parameter" "cert_pem" {
  name            = "/eventstore/cert.pem"
  with_decryption = true
}

data "aws_ssm_parameter" "key_pem" {
  name            = "/eventstore/key.pem"
  with_decryption = true
}

# VPC & Networking

resource "aws_internet_gateway" "eventstore_igw" {
  count  = var.network_type == "public" ? 1 : 0
  vpc_id = aws_vpc.eventstore_vpc.id

  tags = {
    Name = "eventstore-igw"
  }
}

resource "aws_route_table" "eventstore_rt" {
  count  = var.network_type == "public" ? 1 : 0
  vpc_id = aws_vpc.eventstore_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.eventstore_igw[0].id
  }

  tags = {
    Name = "eventstore-rt"
  }
}

resource "aws_route_table_association" "eventstore_rta" {
  count          = var.network_type == "public" ? 1 : 0
  subnet_id      = aws_subnet.eventstore_subnet.id
  route_table_id = aws_route_table.eventstore_rt[0].id
}

resource "aws_vpc" "eventstore_vpc" {
  cidr_block = "172.28.0.0/16"
  tags = {
    Name = "eventstore-vpc"
  }
}

resource "aws_subnet" "eventstore_subnet" {
  vpc_id                  = aws_vpc.eventstore_vpc.id
  cidr_block              = "172.28.1.0/24"
  availability_zone       = local.az
  map_public_ip_on_launch = var.network_type == "public"
}

resource "aws_security_group" "eventstore_sg" {
  name        = "eventstore-sg"
  vpc_id      = aws_vpc.eventstore_vpc.id

  # Internal gRPC communication between nodes
  ingress {
    from_port   = 1113
    to_port     = 1113
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.eventstore_vpc.cidr_block]
    description = "Internal gRPC communication between EventStoreDB nodes"
  }

  # Admin interface access
  ingress {
    from_port   = 2113
    to_port     = 2113
    protocol    = "tcp"
    cidr_blocks = concat(
      [aws_vpc.eventstore_vpc.cidr_block],
      var.bastion_ips
    )
    description = "Admin interface access from VPC and bastion hosts"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "eventstore-sg"
  }
}

# IAM

resource "aws_iam_role" "eventstore_role" {
  name = "eventstore-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "ec2.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "eventstore_policy" {
  name = "eventstore-policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = ["ssm:GetParameter"],
        Effect = "Allow",
        Resource = "arn:aws:ssm:*:*:parameter/eventstore/*"
      },
      {
        Action = ["cloudwatch:PutMetricData"],
        Effect = "Allow",
        Resource = "*"
      },
      {
        Action = ["backup:StartBackupJob", "backup:ListBackupJobs"],
        Effect = "Allow",
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eventstore_attach" {
  role       = aws_iam_role.eventstore_role.name
  policy_arn = aws_iam_policy.eventstore_policy.arn
}

resource "aws_iam_instance_profile" "eventstore_profile" {
  name = "eventstore-profile"
  role = aws_iam_role.eventstore_role.name
}

# Local Gossip Seed IPs or DNS

locals {
  gossip_seeds = var.gossip_mode == "dns" ? [
    for i in range(var.cluster_size) : "esdb-${i + 1}.internal"
  ] : [
    for i in aws_instance.eventstore : i.private_ip
  ]
}

# Instance + Volumes

resource "aws_instance" "eventstore" {
  count = var.cluster_size

  ami                         = local.ami_id
  instance_type               = "m6i.large"
  subnet_id                   = aws_subnet.eventstore_subnet.id
  associate_public_ip_address = var.network_type == "public"
  key_name                    = var.key_pair_name
  vpc_security_group_ids      = [aws_security_group.eventstore_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.eventstore_profile.name

  depends_on = [
    aws_volume_attachment.data_attach[count.index],
    aws_volume_attachment.index_attach[count.index]
  ]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name        = "eventstore-node-${count.index + 1}"
    Cluster     = "eventstore"
    Role        = "eventstoredb"
    Environment = "dev"
  }

  user_data = templatefile("${path.module}/bootstrap.sh.tpl", {
    node_ip     = var.gossip_mode == "dns" ? "esdb-${count.index + 1}.internal" : aws_instance.eventstore[count.index].private_ip
    peer_ips    = join(",", local.gossip_seeds)
    node_name   = "esdb-${count.index + 1}"
    config_text = data.aws_ssm_parameter.eventstore_conf.value
    cert_text   = data.aws_ssm_parameter.cert_pem.value
    key_text    = data.aws_ssm_parameter.key_pem.value
  })
}

resource "aws_ebs_volume" "data_volume" {
  count             = var.cluster_size
  availability_zone = local.az
  size              = 200
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  tags = {
    Name = "eventstore-data-${count.index + 1}"
  }
}

resource "aws_ebs_volume" "index_volume" {
  count             = var.cluster_size
  availability_zone = local.az
  size              = 100
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  tags = {
    Name = "eventstore-index-${count.index + 1}"
  }
}

resource "aws_volume_attachment" "data_attach" {
  count       = var.cluster_size
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data_volume[count.index].id
  instance_id = aws_instance.eventstore[count.index].id
}

resource "aws_volume_attachment" "index_attach" {
  count       = var.cluster_size
  device_name = "/dev/sdg"
  volume_id   = aws_ebs_volume.index_volume[count.index].id
  instance_id = aws_instance.eventstore[count.index].id
}

# Backup Vault

resource "aws_backup_vault" "eventstore_backup" {
  name = "eventstore-backup-vault"
}

resource "aws_backup_plan" "eventstore_plan" {
  name = "eventstore-backup-plan"

  rule {
    rule_name         = "daily-snapshots"
    target_vault_name = aws_backup_vault.eventstore_backup.name
    schedule          = "cron(0 5 * * ? *)"
    lifecycle {
      delete_after = 30
    }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_backup_selection" "eventstore_selection" {
  name         = "eventstore-volumes"
  iam_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/service-role/AWSBackupDefaultServiceRole"
  plan_id      = aws_backup_plan.eventstore_plan.id

  resources = concat(
    [for v in aws_ebs_volume.data_volume : v.arn],
    [for v in aws_ebs_volume.index_volume : v.arn]
  )
}

output "cluster_node_ips" {
  value = [for i in aws_instance.eventstore : i.private_ip]
}

output "gossip_seeds" {
  value = local.gossip_seeds
}

output "backup_vault_name" {
  value = aws_backup_vault.eventstore_backup.name
}