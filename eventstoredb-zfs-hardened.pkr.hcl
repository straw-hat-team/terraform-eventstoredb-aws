packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.6"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type = string
}

variable "eventstore_version" {
  type = string
}

locals {
  amazon_owner_id = "099720109477"
  ubuntu_version = "noble-24.04"
  architecture = "arm64"
  virtualization_type = "hvm"
  os_type = "ubuntu"
  volume_type = "gp3"
  base_ami_name = "${local.os_type}/images/${local.virtualization_type}-ssd-${local.volume_type}/${local.os_type}-${local.ubuntu_version}-${local.architecture}-server"
  filesystem_type = "zfs"
  ami_name = "trogondb/${var.eventstore_version}/${local.filesystem_type}/${local.base_ami_name}-{{timestamp}}"
}

source "amazon-ebs" "eventstoredb" {
  region          = var.region

  source_ami_filter {
    filters = {
      name                = "${local.base_ami_name}-*"
      root-device-type    = "ebs"
      virtualization-type = local.virtualization_type
    }
    most_recent = true
    owners      = [local.amazon_owner_id]
  }

  instance_type   = "t4g.micro"
  ssh_username    = "ubuntu"
  ami_name        = local.ami_name

  launch_block_device_mappings {
    volume_type           = local.volume_type
    device_name           = "/dev/sda1"
    volume_size           = 32
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    ManagedBy   = "packer"
  }
}

build {
  sources = ["source.amazon-ebs.eventstoredb"]

  # provisioner "shell" {
  #   inline = [
  #     "sudo mkdir -p /opt/aws/amazon-cloudwatch-agent/etc"
  #   ]
  # }

  # provisioner "file" {
  #   source      = "files/cloudwatch-agent.json"
  #   destination = "/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json"
  # }

  provisioner "file" {
    source      = "units/eventstore-bootstrap.service"
    destination = "/tmp/eventstore-bootstrap.service"
    # destination = "/etc/systemd/system/eventstore-bootstrap.service"
  }

  provisioner "shell" {
    inline = [
      "chmod +x /tmp/eventstore-bootstrap.service",
      "sudo mv /tmp/eventstore-bootstrap.service /etc/systemd/system/eventstore-bootstrap.service",
      "sudo chown root:root /etc/systemd/system/eventstore-bootstrap.service",
      "sudo chmod 644 /etc/systemd/system/eventstore-bootstrap.service",
    ]
  }
  
  provisioner "file" {
    source      = "scripts/bootstrap.sh"
    destination = "/tmp/bootstrap.sh"
  }

  provisioner "shell" {
    inline = [
      "sudo mv /tmp/bootstrap.sh /usr/local/bin/bootstrap.sh",
      "sudo chown root:root /usr/local/bin/bootstrap.sh",
      "sudo chmod +x /usr/local/bin/bootstrap.sh",
    ]
  }

  # provisioner "file" {
  #   source      = "scripts/cert-watcher.sh"
  #   destination = "/usr/local/bin/cert-watcher.sh"
  # }

  # provisioner "shell" {
  #   inline = [
  #     # "chmod +x /usr/local/bin/cert-watcher.sh",
  #     # "sudo apt-get update",
  #     # "sudo apt-get install -y zfsutils-linux jq amazon-ssm-agent fail2ban unattended-upgrades auditd curl gnupg2",
  #     # "sudo systemctl enable amazon-ssm-agent auditd",
  #     # "dpkg -i /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json || true",
  #     # "systemctl enable cloud-init amazon-cloudwatch-agent",
  #     # "sudo systemctl enable eventstore-bootstrap"
  #     # "systemctl enable --now eventstore-config-watcher.timer"
  #   ]
  # }
}
