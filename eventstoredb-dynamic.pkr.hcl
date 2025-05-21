variable "region" {
  default = "us-east-1"
}

variable "ami_name" {
  default = "eventstoredb-dynamic-hardened"
}

locals {
  ubuntu_ami = "ami-xxxxxxxxxxxxxxxxx" # Replace with Ubuntu 22.04 LTS for your region
}

source "amazon-ebs" "eventstoredb" {
  region          = var.region
  source_ami      = local.ubuntu_ami
  instance_type   = "t3.medium"
  ssh_username    = "ubuntu"
  ami_name        = "${var.ami_name}-${timestamp()}"
  ami_description = "Hardened EventStoreDB AMI with live SSM cert reload, gossip config, and dynamic volume mount"

  ebs_block_device {
    device_name           = "/dev/sda1"
    volume_size           = 32
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  ami_tags = {
    Name      = "eventstoredb-dynamic"
    Role      = "eventstoredb"
    Bootstrap = "enabled"
    Backup    = "true"
  }

  run_tags = {
    Name = "packer-builder"
  }
}

build {
  sources = ["source.amazon-ebs.eventstoredb"]

  provisioner "shell" {
    inline = [
      "set -eux",

      # Basic Hardened OS Setup
      "sudo apt-get update && sudo apt-get upgrade -y",
      "sudo apt-get install -y curl gnupg2 jq software-properties-common apt-transport-https fail2ban auditd amazon-ssm-agent unattended-upgrades",

      "sudo systemctl enable amazon-ssm-agent && sudo systemctl start amazon-ssm-agent",
      "sudo systemctl enable auditd && sudo systemctl start auditd",

      "sudo sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config",
      "sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config",
      "sudo systemctl restart sshd",

      # Install CloudWatch Agent
      "wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb",
      "sudo dpkg -i amazon-cloudwatch-agent.deb && rm amazon-cloudwatch-agent.deb",
      "sudo mkdir -p /opt/aws/amazon-cloudwatch-agent/etc",
      "cat <<EOF | sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  \"logs\": {
    \"logs_collected\": {
      \"files\": {
        \"collect_list\": [
          {\"file_path\": \"/var/log/syslog\", \"log_group_name\": \"/eventstore/syslog\", \"log_stream_name\": \"{instance_id}\"},
          {\"file_path\": \"/var/log/eventstore/eventstore.log\", \"log_group_name\": \"/eventstore/logs\", \"log_stream_name\": \"{instance_id}\"}
        ]
      }
    }
  },
  \"metrics\": {
    \"append_dimensions\": {\"InstanceId\": \"${aws:InstanceId}\"},
    \"metrics_collected\": {
      \"cpu\": { \"measurement\": [\"cpu_usage_idle\"], \"metrics_collection_interval\": 60 }
    }
  }
}
EOF",
      "sudo systemctl enable amazon-cloudwatch-agent && sudo systemctl start amazon-cloudwatch-agent",

      # Install EventStoreDB
      "wget -qO - https://packages.eventstore.com/api/gpg/key/public | sudo apt-key add -",
      "echo 'deb https://packages.eventstore.com/deb/ubuntu jammy main' | sudo tee /etc/apt/sources.list.d/eventstore.list",
      "sudo apt-get update && sudo apt-get install -y eventstore-oss",
      "sudo mkdir -p /etc/systemd/system/eventstore.service.d",
      "echo -e '[Service]\\nRestart=always\\nRestartSec=5' | sudo tee /etc/systemd/system/eventstore.service.d/override.conf",
      "sudo systemctl daemon-reexec && sudo systemctl daemon-reload",
      "sudo systemctl disable eventstore",

      # Bootstrap Script
      "cat <<'EOF' | sudo tee /usr/local/bin/eventstore-bootstrap.sh && sudo chmod +x /usr/local/bin/eventstore-bootstrap.sh
#!/bin/bash
set -eux

if [ -f /etc/eventstore/bootstrapped ] && [ ! -f /etc/eventstore/force_bootstrap ]; then
  echo 'Already bootstrapped'
  exit 0
fi

REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)

mkdir -p /var/log/eventstore /var/lib/eventstore
chown -R eventstore:eventstore /var/log/eventstore /var/lib/eventstore

DATA_DEV=$(lsblk -o NAME,MOUNTPOINT | grep -E '^nvme[0-9]n1[ ]*$' | awk '{print "/dev/" $1}' || true)
if [ -n "$DATA_DEV" ]; then
  mkfs -t ext4 $DATA_DEV || true
  mkdir -p /var/lib/eventstore
  echo "$DATA_DEV /var/lib/eventstore ext4 defaults,nofail 0 2" >> /etc/fstab
  mount -a
  chown -R eventstore:eventstore /var/lib/eventstore
fi

GOSSIP_MODE=$(aws ssm get-parameter --name "/eventstore/config/gossip_mode" --with-decryption --region $REGION --query "Parameter.Value" --output text || echo "ip")
CERT_PATH=$(aws ssm get-parameter --name "/eventstore/ssl/pem" --with-decryption --region $REGION --query "Parameter.Value" --output text || echo "")

mkdir -p /etc/eventstore
if [ -n "$CERT_PATH" ]; then
  echo "$CERT_PATH" | base64 -d > /etc/eventstore/ssl.pem
  chown eventstore:eventstore /etc/eventstore/ssl.pem
fi

cat <<CONFIG > /etc/eventstore/eventstore.conf
Log: /var/log/eventstore
Db: /var/lib/eventstore
ClusterSize: 3
DiscoverViaDns: ${GOSSIP_MODE:-ip}
EnableAtomPubOverHttp: true
CertificateFile: /etc/eventstore/ssl.pem
CertificatePrivateKeyFile: /etc/eventstore/ssl.pem
CertificateFilePassword: ""
IntIp: 0.0.0.0
ExtIp: 0.0.0.0
CONFIG

rm -f /etc/eventstore/force_bootstrap
touch /etc/eventstore/bootstrapped
systemctl enable eventstore
reboot
EOF",

      # Bootstrap service
      "cat <<'EOF' | sudo tee /etc/systemd/system/eventstore-bootstrap.service
[Unit]
Description=EventStoreDB Bootstrap
After=network.target cloud-final.service
ConditionPathExists=!/etc/eventstore/bootstrapped

[Service]
Type=oneshot
ExecStart=/usr/local/bin/eventstore-bootstrap.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF",
      "sudo systemctl daemon-reload && sudo systemctl enable eventstore-bootstrap",

      # Live Cert Reload Watcher
      "cat <<'EOF' | sudo tee /usr/local/bin/eventstore-ssm-watcher.sh && sudo chmod +x /usr/local/bin/eventstore-ssm-watcher.sh
#!/bin/bash
set -euo pipefail

REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
NEW_CERT=$(aws ssm get-parameter --name "/eventstore/ssl/pem" --with-decryption --region $REGION --query "Parameter.Value" --output text || echo "")
CUR_CERT=$(base64 /etc/eventstore/ssl.pem 2>/dev/null || echo "")

if [[ "$NEW_CERT" != "" && "$NEW_CERT" != "$CUR_CERT" ]]; then
  echo "$NEW_CERT" | base64 -d > /etc/eventstore/ssl.pem
  chown eventstore:eventstore /etc/eventstore/ssl.pem
  echo "Reloading EventStore after cert update..."
  systemctl restart eventstore
fi
EOF",

      "cat <<'EOF' | sudo tee /etc/systemd/system/eventstore-config-watcher.service
[Unit]
Description=SSM Config Watcher for EventStoreDB
After=network-online.target

[Service]
ExecStart=/usr/local/bin/eventstore-ssm-watcher.sh
Type=oneshot

[Install]
WantedBy=multi-user.target
EOF",

      "cat <<'EOF' | sudo tee /etc/systemd/system/eventstore-config-watcher.timer
[Unit]
Description=Poll SSM for live cert updates every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=eventstore-config-watcher.service

[Install]
WantedBy=timers.target
EOF",

      "sudo systemctl daemon-reload",
      "sudo systemctl enable --now eventstore-config-watcher.timer",

      # MOTD
      "echo 'EventStoreDB Hardened AMI with dynamic config. Managed by Packer.' | sudo tee /etc/motd"
    ]
  }
}
