#!/bin/bash
set -eux

if [ -f /etc/eventstore/bootstrapped ] && [ ! -f /etc/eventstore/force_bootstrap ]; then
  echo 'Already bootstrapped'
  exit 0
fi

REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
mkdir -p /var/log/eventstore

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

GOSSIP_MODE=$(aws ssm get-parameter --name "/eventstore/config/gossip_mode" --with-decryption --region "$REGION" --query "Parameter.Value" --output text || echo "ip")
CERT_PATH=$(aws ssm get-parameter --name "/eventstore/ssl/pem" --with-decryption --region "$REGION" --query "Parameter.Value" --output text || echo "")

mkdir -p /etc/eventstore
if [ -n "$CERT_PATH" ]; then
  echo "$CERT_PATH" | base64 -d > /etc/eventstore/ssl.pem
  chown eventstore:eventstore /etc/eventstore/ssl.pem
fi

cat > /etc/eventstore/eventstore.conf <<CONF
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
CONF

touch /etc/eventstore/bootstrapped
systemctl enable eventstore
reboot
