#!/bin/bash
set -euo pipefail

REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
NEW_CERT=$(aws ssm get-parameter --name "/eventstore/ssl/pem" --with-decryption --region "$REGION" --query "Parameter.Value" --output text || echo "")
CUR_CERT=$(base64 /etc/eventstore/ssl.pem 2>/dev/null || echo "")

if [[ "$NEW_CERT" != "" && "$NEW_CERT" != "$CUR_CERT" ]]; then
  echo "$NEW_CERT" | base64 -d > /etc/eventstore/ssl.pem
  chown eventstore:eventstore /etc/eventstore/ssl.pem
  echo "Reloading EventStore after cert update..."
  systemctl restart eventstore
fi
