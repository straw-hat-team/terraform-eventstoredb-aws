locals {
  selected_ami = var.amis[var.ami_name]
  instance_count = var.topology == "multi" ? 3 : 1
}

resource "aws_instance" "cluster_node" {
  count         = local.instance_count
  ami           = local.selected_ami
  instance_type = var.instance_type
  subnet_id     = var.network_id
  vpc_security_group_ids = var.public_ip_access_list

  root_block_device {
    volume_type = var.storage.kind
    volume_size = var.storage.size
    iops        = var.storage.iops
    throughput  = var.storage.throughput
  }

  tags = {
    Name            = "${var.cluster_name}-node-${count.index + 1}"
    Version         = var.server_version
    Infrastructure  = var.infrastructure_type
  }
} 