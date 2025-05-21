packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.6"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  default = "us-east-1"
}

variable "ami_name" {
  default = "eventstoredb-zfs-hardened"
}

locals {
  amazon_owner_id = "099720109477"
  ubuntu_version = "noble-24.04"
  architecture = "arm64"
  virtualization_type = "hvm"
}

source "amazon-ebs" "eventstoredb" {
  region          = var.region

  source_ami_filter {
    filters = {
      # Example: ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-20250325
      name                = "ubuntu/images/${local.virtualization_type}-ssd-*/ubuntu-${local.ubuntu_version}-${local.architecture}-server-*"
      root-device-type    = "ebs"
      virtualization-type = local.virtualization_type
    }
    most_recent = true
    owners      = [local.amazon_owner_id]
  }

  instance_type   = "t2.micro"
  ssh_username    = "ubuntu"
  ami_name        = "${var.ami_name}-{{timestamp}}"
  ami_description = "ZFS + EventStoreDB with dynamic config via SSM and CloudWatch"

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 32
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    Name   = "eventstoredb-zfs"
    Role   = "eventstoredb"
    Backup = "true"
  }

  run_tags = {
    Name = "packer-builder"
  }
}

build {
  sources = ["source.amazon-ebs.eventstoredb"]

  provisioner "file" {
    source      = "files/cloudwatch-agent.json"
    destination = "/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json"
  }

  provisioner "file" {
    source      = "units/"
    destination = "/etc/systemd/system/"
  }

  provisioner "file" {
    source      = "scripts/bootstrap.sh"
    destination = "/usr/local/bin/bootstrap.sh"
  }

  provisioner "file" {
    source      = "scripts/cert-watcher.sh"
    destination = "/usr/local/bin/cert-watcher.sh"
  }

  provisioner "shell" {
    inline = [
      "chmod +x /usr/local/bin/bootstrap.sh /usr/local/bin/cert-watcher.sh",
      "apt-get update && apt-get install -y zfsutils-linux jq amazon-ssm-agent fail2ban unattended-upgrades auditd curl gnupg2",
      "systemctl enable amazon-ssm-agent auditd",
      "dpkg -i /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json || true",
      "systemctl enable cloud-init amazon-cloudwatch-agent",
      "systemctl enable eventstore-bootstrap",
      "systemctl enable --now eventstore-config-watcher.timer"
    ]
  }
}
