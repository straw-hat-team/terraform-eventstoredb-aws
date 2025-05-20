# Terraform EventStoreDB AWS

## Certificate Rotation

The EventStoreDB cluster uses certificates stored in AWS Systems Manager Parameter Store. To ensure secure certificate rotation:

1. Store new certificates in SSM Parameter Store under the same paths:
   - `/eventstore/cert.pem`
   - `/eventstore/key.pem`

2. After updating the certificates, you can trigger a rolling restart of the EventStoreDB service on each node using AWS Systems Manager Run Command:

```bash
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Role,Values=eventstoredb" \
  --parameters 'commands=["systemctl restart eventstore"]' \
  --comment "Restart EventStoreDB after certificate rotation"
```

Alternatively, you can set up an AWS Lambda function to monitor SSM parameter changes and automatically trigger the restart.
