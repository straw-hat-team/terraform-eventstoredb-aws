#!/bin/bash
set -eux

# Check if already bootstrapped
if [ -f /etc/eventstore/bootstrapped ] && [ ! -f /etc/eventstore/force_bootstrap ]; then
  echo 'Already bootstrapped'
  exit 0
fi

# Get AWS region
# REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)

# Create log directory
# mkdir -p /var/log/eventstore
# chown eventstore:eventstore /var/log/eventstore

# Setup ZFS storage
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

# Get configuration from SSM
# GOSSIP_MODE=$(aws ssm get-parameter --name "/eventstore/config/gossip_mode" --with-decryption --region "$REGION" --query "Parameter.Value" --output text || echo "ip")
# CERT_PATH=$(aws ssm get-parameter --name "/eventstore/ssl/pem" --with-decryption --region "$REGION" --query "Parameter.Value" --output text || echo "")

# Setup SSL certificate
# mkdir -p /etc/eventstore
# if [ -n "$CERT_PATH" ]; then
#   echo "$CERT_PATH" | base64 -d > /etc/eventstore/ssl.pem
#   chown eventstore:eventstore /etc/eventstore/ssl.pem
#   chmod 600 /etc/eventstore/ssl.pem
# fi

# # Create EventStoreDB configuration
# cat > /etc/eventstore/eventstore.conf <<CONF
# DiscoverViaDns: ${GOSSIP_MODE:-ip}
# EnableAtomPubOverHttp: true
# CertificateFile: /etc/eventstore/ssl.pem
# CertificatePrivateKeyFile: /etc/eventstore/ssl.pem
# CertificateFilePassword: ""
# IntIp: 0.0.0.0
# ExtIp: 0.0.0.0
# CONF

# chown eventstore:eventstore /etc/eventstore/eventstore.conf
# chmod 600 /etc/eventstore/eventstore.conf

# Mark as bootstrapped and enable service
touch /etc/eventstore/bootstrapped
# Enable and start the EventStoreDB service
systemctl enable eventstore.service