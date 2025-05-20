#!/bin/bash
set -e

# Install CloudWatch Agent
apt-get update -y
apt-get install -y amazon-cloudwatch-agent

# CloudWatch config
cat <<EOC > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "metrics": {
    "namespace": "EventStoreDB",
    "append_dimensions": {
      "InstanceId": "\${aws:InstanceId}"
    },
    "metrics_collected": {
      "disk": {
        "measurement": ["used_percent"],
        "resources": ["/"]
      },
      "mem": {
        "measurement": ["mem_used_percent"]
      },
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
        "totalcpu": true
      }
    }
  }
}
EOC

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s

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

# Write config
mkdir -p /etc/eventstore /etc/eventstore/certs

cat <<EOF > /etc/eventstore/eventstore.conf
${config_text}
IntIp: ${node_ip}
ExtIp: ${node_ip}
ClusterSize: ${var.cluster_size}
GossipSeed: [${peer_ips}]
Db: /var/lib/eventstore/data
Index: /var/lib/eventstore/index
EOF

cat <<EOF > /etc/eventstore/certs/cert.pem
${cert_text}
EOF

cat <<EOF > /etc/eventstore/certs/key.pem
${key_text}
EOF

chmod 600 /etc/eventstore/certs/key.pem

# Enable and start EventStoreDB
systemctl enable eventstore
systemctl start eventstore
