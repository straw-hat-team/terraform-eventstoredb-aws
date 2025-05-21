variable "region" {
  default = "us-east-1"
}

variable "ami_name" {
  default = "eventstoredb-zfs-hardened"
}

locals {
  ubuntu_ami = "ami-xxxxxxxxxxxxxxxxx" # Ubuntu 22.04 LTS
}

source "amazon-ebs" "eventstoredb" {
  region          = var.region
  source_ami      = local.ubuntu_ami
  instance_type   = "t3.medium"
  ssh_username    = "ubuntu"
  ami_name        = "${var.ami_name}-${timestamp()}"
  ami_description = "EventStoreDB hardened AMI with ZFS, dynamic SSM config, cert injection, and CloudWatch"

  ebs_block_device {
    device_name           = "/dev/sda1"
    volume_size           = 32
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  ami_tags = {
    Name      = "eventstoredb-zfs"
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

      "sudo apt-get update && sudo apt-get upgrade -y",
      "sudo apt-get install -y curl gnupg2 jq zfsutils-linux software-properties-common apt-transport-https fail2ban auditd amazon-ssm-agent unattended-upgrades",

      "sudo systemctl enable amazon-ssm-agent && sudo systemctl start amazon-ssm-agent",
      "sudo systemctl enable auditd && sudo systemctl start auditd",

      "sudo sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config",
      "sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config",
      "sudo systemctl restart sshd",

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

      "wget -qO - https://packages.eventstore.com/api/gpg/key/public | sudo apt-key add -",
      "echo 'deb https://packages.eventstore.com/deb/ubuntu jammy main' | sudo tee /etc/apt/sources.list.d/eventstore.list",
      "sudo apt-get update && sudo apt-get install -y eventstore-oss",
      "sudo mkdir -p /etc/systemd/system/eventstore.service.d",
      "cat <<EOF | sudo tee /etc/systemd/system/eventstore.service.d/override.conf
[Unit]
After=zfs-mount.service
Requires=zfs-mount.service

[Service]
Restart=always
RestartSec=5
EOF",
      "sudo systemctl daemon-reexec && sudo systemctl daemon-reload",
      "sudo systemctl disable eventstore",

      "cat <<'EOF' | sudo tee /usr/local/bin/eventstore-bootstrap.sh && sudo chmod +x /usr/local/bin/eventstore-bootstrap.sh
#!/bin/bash
set -eux

if [ -f /etc/eventstore/bootstrapped ] && [ ! -f /etc/eventstore/force_bootstrap ]; then
  echo 'Already bootstrapped'
  exit 0
fi

REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
mkdir -p /var/log/eventstore
chown -R eventstore:eventstore /var/log/eventstore

DATA_DEV=$(lsblk -o NAME,MOUNTPOINT | grep -E '^nvme[0-9]n1[ ]*$' | awk '{print "/dev/" $1}' || true)
if [ -n "$DATA_DEV" ]; then
  if ! zpool list | grep -q espool; then
    zpool create -f espool "$DATA_DEV"
    zfs set mountpoint=/var/lib/eventstore espool
    zfs set compression=off espool
    zfs set atime=off espool
    zfs set recordsize=128K espool
  else
    zpool import espool || true
    zfs mount espool || true
  fi
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
ClusterSize: 1
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

      "echo 'EventStoreDB Hardened AMI with ZFS. Managed by Packer.' | sudo tee /etc/motd"
    ]
  }
}
