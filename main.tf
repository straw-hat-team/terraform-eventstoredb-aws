provider "aws" {
  region = "us-east-1"
}

variable "network_type" {
  description = "Specify if the instance should be public or private"
  type        = string
  default     = "private"
}

variable "key_pair_name" {}

resource "aws_vpc" "eventstore_vpc" {
  cidr_block = "172.28.0.0/16"
  tags = {
    Name = "eventstore-vpc"
  }
}

resource "aws_subnet" "eventstore_subnet" {
  vpc_id                  = aws_vpc.eventstore_vpc.id
  cidr_block              = "172.28.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = var.network_type == "public"

  tags = {
    Name = "eventstore-subnet"
  }
}

resource "aws_internet_gateway" "igw" {
  count  = var.network_type == "public" ? 1 : 0
  vpc_id = aws_vpc.eventstore_vpc.id
}

resource "aws_route_table" "public_rt" {
  count  = var.network_type == "public" ? 1 : 0
  vpc_id = aws_vpc.eventstore_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw[0].id
  }

  tags = {
    Name = "public-route-table"
  }
}

resource "aws_route_table_association" "public_rta" {
  count          = var.network_type == "public" ? 1 : 0
  subnet_id      = aws_subnet.eventstore_subnet.id
  route_table_id = aws_route_table.public_rt[0].id
}

resource "aws_security_group" "eventstore_sg" {
  name        = "eventstore-sg"
  description = "Allow EventStoreDB traffic"
  vpc_id      = aws_vpc.eventstore_vpc.id

  ingress {
    from_port   = 2113
    to_port     = 2113
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 1113
    to_port     = 1113
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "eventstore-sg"
  }
}

resource "aws_ebs_volume" "data_volume" {
  availability_zone = "us-east-1a"
  size              = 200
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  tags = {
    Name = "eventstore-data"
  }
}

resource "aws_ebs_volume" "index_volume" {
  availability_zone = "us-east-1a"
  size              = 100
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  tags = {
    Name = "eventstore-index"
  }
}

resource "aws_instance" "eventstore" {
  ami                         = "ami-xxxxxxxxxxxxxxxxx" # Ubuntu 22.04 AMI
  instance_type               = "m6i.large"
  subnet_id                   = aws_subnet.eventstore_subnet.id
  associate_public_ip_address = var.network_type == "public"
  key_name                    = var.key_pair_name
  vpc_security_group_ids      = [aws_security_group.eventstore_sg.id]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "eventstore-node"
  }

  user_data = <<-EOF
              #!/bin/bash
              set -e
              # Set EventStoreDB environment variables
              echo "EVENTSTORE_DB=/var/lib/eventstore/data" >> /etc/environment
              echo "EVENTSTORE_INDEX=/var/lib/eventstore/index" >> /etc/environment

              # Format and mount data volume
              mkfs.ext4 /dev/xvdf
              mkdir -p /var/lib/eventstore/data
              mount /dev/xvdf /var/lib/eventstore/data

              # Format and mount index volume
              mkfs.ext4 /dev/xvdg
              mkdir -p /var/lib/eventstore/index
              mount /dev/xvdg /var/lib/eventstore/index

              echo "/dev/xvdf /var/lib/eventstore/data ext4 defaults,nofail 0 2" >> /etc/fstab
              echo "/dev/xvdg /var/lib/eventstore/index ext4 defaults,nofail 0 2" >> /etc/fstab

              # Pull config and certs from S3 (or another source)
              aws s3 cp s3://my-eventstore-config/eventstore.conf /etc/eventstore/eventstore.conf
              aws s3 cp s3://my-eventstore-certs/ /etc/eventstore/certs/ --recursive

              # Start eventstoredb
              systemctl enable eventstore
              systemctl start eventstore
              EOF
}

resource "aws_volume_attachment" "data_attach" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data_volume.id
  instance_id = aws_instance.eventstore.id
}

resource "aws_volume_attachment" "index_attach" {
  device_name = "/dev/sdg"
  volume_id   = aws_ebs_volume.index_volume.id
  instance_id = aws_instance.eventstore.id
}
