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

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner of the resources (optional)"
  type        = string
  default     = null
}

variable "alarm_email" {
  description = "Email address for CloudWatch alarm notifications"
  type        = string
  default     = null
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

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Get current region and account info
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  ami_id = var.ami_id != null ? var.ami_id : data.aws_ami.ubuntu[0].id
  az     = var.availability_zone != null ? var.availability_zone : data.aws_availability_zones.available.names[0]
  
  common_tags = {
    Environment = var.environment
    Cluster     = "eventstore"
    Role        = "eventstoredb"
    Owner       = var.owner
    ManagedBy   = "terraform"
  }
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
  tags       = merge(local.common_tags, { Name = "eventstore-vpc" })
}

resource "aws_subnet" "eventstore_subnet" {
  vpc_id                  = aws_vpc.eventstore_vpc.id
  cidr_block              = "172.28.1.0/24"
  availability_zone       = local.az
  map_public_ip_on_launch = var.network_type == "public"
  tags                    = merge(local.common_tags, { Name = "eventstore-subnet" })
}

resource "aws_security_group" "eventstore_sg" {
  name        = "eventstore-sg"
  vpc_id      = aws_vpc.eventstore_vpc.id
  tags        = merge(local.common_tags, { Name = "eventstore-sg" })

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
        Action = ["ssm:GetParameter", "ssm:GetParameters"],
        Effect = "Allow",
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/eventstore/*"
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
  disable_api_termination     = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  depends_on = [
    aws_volume_attachment.data_attach[count.index],
    aws_volume_attachment.index_attach[count.index]
  ]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/bootstrap.sh.tpl", {
    node_ip     = var.gossip_mode == "dns" ? "esdb-${count.index + 1}.internal" : aws_instance.eventstore[count.index].private_ip
    peer_ips    = join(",", local.gossip_seeds)
    node_name   = "esdb-${count.index + 1}"
    config_text = data.aws_ssm_parameter.eventstore_conf.value
    cert_text   = data.aws_ssm_parameter.cert_pem.value
    key_text    = data.aws_ssm_parameter.key_pem.value
    environment = var.environment
  })

  tags = merge(local.common_tags, {
    Name = "eventstore-node-${count.index + 1}"
  })
}

resource "aws_ebs_volume" "data_volume" {
  count             = var.cluster_size
  availability_zone = local.az
  size              = 200
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  tags              = merge(local.common_tags, { Name = "eventstore-data-${count.index + 1}" })
}

resource "aws_ebs_volume" "index_volume" {
  count             = var.cluster_size
  availability_zone = local.az
  size              = 100
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  tags              = merge(local.common_tags, { Name = "eventstore-index-${count.index + 1}" })
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

# Custom Backup Role
resource "aws_iam_role" "backup_role" {
  name = "eventstore-backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "backup_policy" {
  role       = aws_iam_role.backup_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_vault" "eventstore_backup" {
  name = "eventstore-backup-vault"
  tags = local.common_tags
}

resource "aws_backup_plan" "eventstore_plan" {
  name = "eventstore-backup-plan"
  tags = local.common_tags

  rule {
    rule_name         = "daily-snapshots"
    target_vault_name = aws_backup_vault.eventstore_backup.name
    schedule          = "cron(0 5 * * ? *)"
    lifecycle {
      delete_after = 30
      cold_storage_after = 7
    }
    tags = local.common_tags
  }
}

resource "aws_backup_selection" "eventstore_selection" {
  name         = "eventstore-volumes"
  iam_role_arn = aws_iam_role.backup_role.arn
  plan_id      = aws_backup_plan.eventstore_plan.id

  resources = concat(
    [for v in aws_ebs_volume.data_volume : v.arn],
    [for v in aws_ebs_volume.index_volume : v.arn]
  )

  tags = local.common_tags
}

# SNS Topic for alarms
resource "aws_sns_topic" "eventstore_alarms" {
  name = "eventstore-alarms"
  tags = local.common_tags
}

resource "aws_sns_topic_policy" "eventstore_alarms" {
  arn = aws_sns_topic.eventstore_alarms.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.eventstore_alarms.arn
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "eventstore_alarms" {
  count     = var.alarm_email != null ? 1 : 0
  topic_arn = aws_sns_topic.eventstore_alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# CloudWatch Alarms
locals {
  alarm_thresholds = {
    disk_usage_warning  = 80
    disk_usage_critical = 90
    memory_usage       = 85
    cpu_usage         = 80
  }
}

# EC2 Status Check Alarms
resource "aws_cloudwatch_metric_alarm" "ec2_status_check" {
  count               = var.cluster_size
  alarm_name          = "eventstore-ec2-status-${count.index + 1}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period             = 60
  statistic          = "Maximum"
  threshold          = 0
  alarm_description  = "EC2 instance status check failed"
  alarm_actions      = [aws_sns_topic.eventstore_alarms.arn]
  ok_actions         = [aws_sns_topic.eventstore_alarms.arn]

  dimensions = {
    InstanceId = aws_instance.eventstore[count.index].id
  }

  tags = local.common_tags
}

# EBS Volume Status Alarms
resource "aws_cloudwatch_metric_alarm" "ebs_status" {
  count               = var.cluster_size * 2 # For both data and index volumes
  alarm_name          = "eventstore-ebs-status-${count.index + 1}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "VolumeStatusCheckFailed"
  namespace           = "AWS/EBS"
  period             = 60
  statistic          = "Maximum"
  threshold          = 0
  alarm_description  = "EBS volume status check failed"
  alarm_actions      = [aws_sns_topic.eventstore_alarms.arn]
  ok_actions         = [aws_sns_topic.eventstore_alarms.arn]

  dimensions = {
    VolumeId = count.index < var.cluster_size ? 
      aws_ebs_volume.data_volume[count.index].id : 
      aws_ebs_volume.index_volume[count.index - var.cluster_size].id
  }

  tags = local.common_tags
}

# Disk Usage Alarms
resource "aws_cloudwatch_metric_alarm" "disk_usage_warning" {
  count               = var.cluster_size
  alarm_name          = "eventstore-disk-usage-warning-${count.index + 1}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "disk_used_percent"
  namespace           = "EventStoreDB"
  period             = 300
  statistic          = "Average"
  threshold          = local.alarm_thresholds.disk_usage_warning
  alarm_description  = "Disk usage is above warning threshold"
  alarm_actions      = [aws_sns_topic.eventstore_alarms.arn]
  ok_actions         = [aws_sns_topic.eventstore_alarms.arn]

  dimensions = {
    InstanceId = aws_instance.eventstore[count.index].id
    Cluster    = "eventstore"
    Role       = "eventstoredb"
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "disk_usage_critical" {
  count               = var.cluster_size
  alarm_name          = "eventstore-disk-usage-critical-${count.index + 1}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "disk_used_percent"
  namespace           = "EventStoreDB"
  period             = 300
  statistic          = "Average"
  threshold          = local.alarm_thresholds.disk_usage_critical
  alarm_description  = "Disk usage is above critical threshold"
  alarm_actions      = [aws_sns_topic.eventstore_alarms.arn]
  ok_actions         = [aws_sns_topic.eventstore_alarms.arn]

  dimensions = {
    InstanceId = aws_instance.eventstore[count.index].id
    Cluster    = "eventstore"
    Role       = "eventstoredb"
  }

  tags = local.common_tags
}

# Memory Usage Alarm
resource "aws_cloudwatch_metric_alarm" "memory_usage" {
  count               = var.cluster_size
  alarm_name          = "eventstore-memory-usage-${count.index + 1}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "mem_used_percent"
  namespace           = "EventStoreDB"
  period             = 300
  statistic          = "Average"
  threshold          = local.alarm_thresholds.memory_usage
  alarm_description  = "Memory usage is above threshold"
  alarm_actions      = [aws_sns_topic.eventstore_alarms.arn]
  ok_actions         = [aws_sns_topic.eventstore_alarms.arn]

  dimensions = {
    InstanceId = aws_instance.eventstore[count.index].id
    Cluster    = "eventstore"
    Role       = "eventstoredb"
  }

  tags = local.common_tags
}

# CPU Usage Alarm
resource "aws_cloudwatch_metric_alarm" "cpu_usage" {
  count               = var.cluster_size
  alarm_name          = "eventstore-cpu-usage-${count.index + 1}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "cpu_usage_user"
  namespace           = "EventStoreDB"
  period             = 300
  statistic          = "Average"
  threshold          = local.alarm_thresholds.cpu_usage
  alarm_description  = "CPU usage is above threshold"
  alarm_actions      = [aws_sns_topic.eventstore_alarms.arn]
  ok_actions         = [aws_sns_topic.eventstore_alarms.arn]

  dimensions = {
    InstanceId = aws_instance.eventstore[count.index].id
    Cluster    = "eventstore"
    Role       = "eventstoredb"
  }

  tags = local.common_tags
}

output "cluster_node_ips" {
  value = [for i in aws_instance.eventstore : i.private_ip]
}

output "node_dns_names" {
  value = [for i in aws_instance.eventstore : i.private_dns]
}

output "gossip_seeds" {
  value = local.gossip_seeds
}

output "backup_vault_name" {
  value = aws_backup_vault.eventstore_backup.name
}