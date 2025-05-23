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

# Validate required environment variables
if [ -z "${environment}" ]; then
  echo "Error: environment variable is required"
  exit 1
fi

if [ -z "${node_ip}" ]; then
  echo "Error: node_ip variable is required"
  exit 1
fi

if [ -z "${peer_ips}" ]; then
  echo "Error: peer_ips variable is required"
  exit 1
fi

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
        "measurement": ["used_percent", "used", "free", "total", "inodes_free", "inodes_total"],
        "resources": ["/", "/var/lib/eventstore/data", "/var/lib/eventstore/index"]
      },
      "mem": {
        "measurement": ["mem_used_percent", "mem_used", "mem_total", "mem_free", "mem_available"]
      },
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system", "cpu_usage_iowait", "cpu_usage_steal", "cpu_usage_softirq"],
        "totalcpu": true
      },
      "net": {
        "measurement": ["net_bytes_recv", "net_bytes_sent", "net_packets_recv", "net_packets_sent", "net_err_in", "net_err_out", "net_drop_in", "net_drop_out"],
        "resources": ["eth0"]
      },
      "swap": {
        "measurement": ["swap_used_percent", "swap_used", "swap_free"]
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
          },
          {
            "file_path": "/var/log/eventstore/*.log",
            "log_group_name": "/eventstore/${environment}/eventstore",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/syslog",
            "log_group_name": "/eventstore/${environment}/syslog",
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

# Handle SSL certificates if provided
if [ ! -z "${cert_text}" ] && [ ! -z "${key_text}" ] && [ ! -z "${ca_text}" ]; then
  echo "Configuring SSL certificates..."
  
  # Create certificate directories with proper permissions
  mkdir -p /etc/eventstore/certs/ca
  chmod 700 /etc/eventstore/certs
  chmod 700 /etc/eventstore/certs/ca

  # Write certificates
  cat <<EOF > /etc/eventstore/certs/node.crt
${cert_text}
EOF

  cat <<EOF > /etc/eventstore/certs/node.key
${key_text}
EOF

  cat <<EOF > /etc/eventstore/certs/ca/ca.crt
${ca_text}
EOF

  # Set proper ownership and permissions
  chown -R eventstore:eventstore /etc/eventstore/certs
  chmod 600 /etc/eventstore/certs/node.key
  chmod 644 /etc/eventstore/certs/node.crt
  chmod 644 /etc/eventstore/certs/ca/ca.crt

  # Update system CA certificates
  cp /etc/eventstore/certs/ca/ca.crt /usr/local/share/ca-certificates/eventstore_ca.crt
  update-ca-certificates
fi

# Write config
echo "Writing EventStoreDB configuration..."
mkdir -p /etc/eventstore

# Default EventStoreDB configuration if not provided
if [ -z "${config_text}" ]; then
  config_text="RunProjections: All
StartStandardProjections: true
EnableAtomPubOverHTTP: true
EnableExternalTCP: true
EnableInternalTCP: true
HttpPort: 2113
ExternalTcpPort: 1113
InternalTcpPort: 1112
GossipPort: 2112
CertificateFile: /etc/eventstore/certs/node.crt
CertificatePrivateKeyFile: /etc/eventstore/certs/node.key
TrustedRootCertificatesPath: /etc/eventstore/certs/ca"
fi

cat <<EOF > /etc/eventstore/eventstore.conf
${config_text}
IntIp: ${node_ip}
ExtIp: ${node_ip}
ClusterSize: ${cluster_size:-3}
GossipSeed: [${peer_ips}]
Db: /var/lib/eventstore/data
Index: /var/lib/eventstore/index
EOF

# Set proper ownership for config
chown eventstore:eventstore /etc/eventstore/eventstore.conf
chmod 644 /etc/eventstore/eventstore.conf

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

# Create certificate expiration check script
cat <<'EOF' > /usr/local/bin/check-cert-expiration.sh
#!/bin/bash

CERT_FILE="/etc/eventstore/certs/node.crt"
if [ ! -f "$CERT_FILE" ]; then
    echo "Certificate file not found: $CERT_FILE"
    exit 1
fi

# Get certificate expiration date
EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)
EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s)
CURRENT_EPOCH=$(date +%s)
DAYS_LEFT=$(( ($EXPIRY_EPOCH - $CURRENT_EPOCH) / 86400 ))

# Send metric to CloudWatch
aws cloudwatch put-metric-data \
    --namespace EventStoreDB \
    --metric-name CertificateExpirationDays \
    --value $DAYS_LEFT \
    --unit Count \
    --dimensions InstanceId=$(curl -s http://169.254.169.254/latest/meta-data/instance-id),Cluster=eventstore,Role=eventstoredb
EOF

chmod +x /usr/local/bin/check-cert-expiration.sh

# Add certificate check to crontab
(crontab -l 2>/dev/null; echo "0 0 * * * /usr/local/bin/check-cert-expiration.sh") | crontab -

# Create EventStoreDB metrics collection script
cat <<'EOF' > /usr/local/bin/collect-eventstore-metrics.sh
#!/bin/bash

# Function to get EventStoreDB metrics
get_eventstore_metrics() {
    local metrics=$(curl -s http://localhost:2113/stats)
    
    # Extract metrics
    local write_events=$(echo "$metrics" | jq -r '.proc.writeEventsPerSecond')
    local read_events=$(echo "$metrics" | jq -r '.proc.readEventsPerSecond')
    local queue_length=$(echo "$metrics" | jq -r '.proc.queueLength')
    local projection_time=$(echo "$metrics" | jq -r '.proc.projectionProcessingTime')
    
    # Send metrics to CloudWatch
    aws cloudwatch put-metric-data \
        --namespace EventStoreDB \
        --metric-name WriteEventsPerSecond \
        --value $write_events \
        --unit Count \
        --dimensions InstanceId=$(curl -s http://169.254.169.254/latest/meta-data/instance-id),Cluster=eventstore,Role=eventstoredb
    
    aws cloudwatch put-metric-data \
        --namespace EventStoreDB \
        --metric-name ReadEventsPerSecond \
        --value $read_events \
        --unit Count \
        --dimensions InstanceId=$(curl -s http://169.254.169.254/latest/meta-data/instance-id),Cluster=eventstore,Role=eventstoredb
    
    aws cloudwatch put-metric-data \
        --namespace EventStoreDB \
        --metric-name QueueLength \
        --value $queue_length \
        --unit Count \
        --dimensions InstanceId=$(curl -s http://169.254.169.254/latest/meta-data/instance-id),Cluster=eventstore,Role=eventstoredb
    
    aws cloudwatch put-metric-data \
        --namespace EventStoreDB \
        --metric-name ProjectionProcessingTime \
        --value $projection_time \
        --unit Milliseconds \
        --dimensions InstanceId=$(curl -s http://169.254.169.254/latest/meta-data/instance-id),Cluster=eventstore,Role=eventstoredb
}

# Run metrics collection
get_eventstore_metrics
EOF

chmod +x /usr/local/bin/collect-eventstore-metrics.sh

# Add EventStoreDB metrics collection to crontab
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/collect-eventstore-metrics.sh") | crontab -

# Install required packages
apt-get update -y
apt-get install -y jq

echo "Bootstrap script completed successfully"
