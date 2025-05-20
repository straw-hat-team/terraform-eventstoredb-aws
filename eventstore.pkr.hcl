variable "aws_region" {
  default = "us-east-1"
}

source "amazon-ebs" "esdb" {
  region                  = var.aws_region
  instance_type           = "t3.medium"
  ami_name                = "eventstore-custom-{{timestamp}}"
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      virtualization-type = "hvm"
      architecture        = "x86_64"
    }
    owners      = ["099720109477"]
    most_recent = true
  }
  ssh_username            = "ubuntu"
}

build {
  sources = ["source.amazon-ebs.esdb"]

  provisioner "shell" {
    inline = [
      "sudo apt-get update -y",
      "sudo apt-get install -y amazon-cloudwatch-agent",
      "curl -s https://install.eventstore.org | bash",
      "sudo apt-get install -y eventstore-oss",
      "sudo systemctl disable eventstore",
      "sudo systemctl stop eventstore",
      "sudo cloud-init clean",
      "sudo rm -rf /var/lib/cloud/*"
    ]
  }
}
