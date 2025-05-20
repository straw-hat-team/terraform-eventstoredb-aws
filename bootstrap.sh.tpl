#!/bin/bash

# Check if already bootstrapped
if [ -f /etc/eventstore/bootstrapped ]; then
  echo "Already bootstrapped. Exiting."
  exit 0
fi
touch /etc/eventstore/bootstrapped

# Redirect all output to both console and log file
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "Starting EventStoreDB node bootstrap script"
set -e

# Install CloudWatch Agent
echo "Installing CloudWatch Agent..."
apt-get update -y
apt-get install -y amazon-cloudwatch-agent

# CloudWatch config
echo "Configuring CloudWatch Agent..."
cat <<EOC > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "metrics": {
    "namespace": "EventStoreDB",
    "append_dimensions": {
      "InstanceId": "\${aws:InstanceId}",
      "Cluster": "eventstore",
      "Environment": "${environment}",
      "Role": "eventstoredb"
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
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/user-data.log",
            "log_group_name": "/eventstore/${environment}/user-data",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          }
        ]
      }
    }
  }
}
EOC

echo "Starting CloudWatch Agent..."
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s

# Enable and start CloudWatch Agent
echo "Enabling CloudWatch Agent service..."
systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

# Format and mount data volume
echo "Setting up data volume..."
# Find the first available block device that's not mounted and not the root device
DATA_DEV=$(lsblk -o NAME,MOUNTPOINT | grep -vE "boot|/" | awk '{print "/dev/"$1}' | head -n 1)
if [ -z "$DATA_DEV" ]; then
    echo "Error: Could not find data device"
    exit 1
fi
echo "Using data device: $DATA_DEV"
# Wait for device to be available
until [ -b "$DATA_DEV" ]; do 
    echo "Waiting for data device $DATA_DEV to be available..."
    sleep 1
done
mkfs.ext4 "$DATA_DEV"
mkdir -p /var/lib/eventstore/data
mount "$DATA_DEV" /var/lib/eventstore/data

# Format and mount index volume
echo "Setting up index volume..."
# Find the second available block device that's not mounted and not the root device
INDEX_DEV=$(lsblk -o NAME,MOUNTPOINT | grep -vE "boot|/" | awk '{print "/dev/"$1}' | tail -n 1)
if [ -z "$INDEX_DEV" ]; then
    echo "Error: Could not find index device"
    exit 1
fi
echo "Using index device: $INDEX_DEV"
# Wait for device to be available
until [ -b "$INDEX_DEV" ]; do 
    echo "Waiting for index device $INDEX_DEV to be available..."
    sleep 1
done
mkfs.ext4 "$INDEX_DEV"
mkdir -p /var/lib/eventstore/index
mount "$INDEX_DEV" /var/lib/eventstore/index

echo "Configuring fstab..."
echo "$DATA_DEV /var/lib/eventstore/data ext4 defaults,nofail 0 2" >> /etc/fstab
echo "$INDEX_DEV /var/lib/eventstore/index ext4 defaults,nofail 0 2" >> /etc/fstab

# Write config
echo "Writing EventStoreDB configuration..."
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
echo "Enabling and starting EventStoreDB service..."

# Create systemd override directory
mkdir -p /etc/systemd/system/eventstore.service.d

# Write systemd override configuration
cat <<EOF > /etc/systemd/system/eventstore.service.d/override.conf
[Service]
Restart=always
RestartSec=5
LimitNOFILE=100000
EOF

# Reload systemd to pick up changes
systemctl daemon-reload

# Enable and start EventStoreDB
systemctl enable eventstore
systemctl start eventstore

# Wait for EventStoreDB to be healthy
echo "Waiting for EventStoreDB to be healthy..."
max_attempts=30
attempt=1
while [ $attempt -le $max_attempts ]; do
  if curl --fail --max-time 2 http://localhost:2113/gossip > /dev/null 2>&1; then
    echo "EventStoreDB is healthy!"
    break
  fi
  echo "Attempt $attempt/$max_attempts: EventStoreDB not ready yet..."
  sleep 5
  attempt=$((attempt + 1))
done

if [ $attempt -gt $max_attempts ]; then
  echo "Error: EventStoreDB failed to become healthy after $max_attempts attempts"
  exit 1
fi

echo "Bootstrap script completed successfully"
