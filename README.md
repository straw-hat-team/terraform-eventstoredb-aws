# Terraform EventStoreDB AWS

## Certificate Rotation

The EventStoreDB cluster uses certificates stored in AWS Systems Manager Parameter Store. To ensure secure certificate rotation:

1. Store certificates in SSM Parameter Store under these paths:
   - `/eventstore/cert.pem` - Node certificate
   - `/eventstore/key.pem` - Node private key
   - `/eventstore/ca.pem` - CA certificate

2. After updating the certificates, you can trigger a rolling restart of the EventStoreDB service on each node using AWS Systems Manager Run Command:

```bash
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --targets "Key=tag:Role,Values=eventstoredb" \
  --parameters 'commands=["systemctl restart eventstore"]' \
  --comment "Restart EventStoreDB after certificate rotation"
```

Alternatively, you can set up an AWS Lambda function to monitor SSM parameter changes and automatically trigger the restart.

### Certificate Security

The module implements several security measures for certificate handling:

1. Certificates are stored in SSM Parameter Store with encryption
2. Certificate files are stored with proper permissions:
   - Node private key: 600 (owner read/write only)
   - Node certificate: 644 (owner read/write, group/others read)
   - CA certificate: 644 (owner read/write, group/others read)
3. Certificate directories have restricted permissions:
   - /etc/eventstore/certs: 700 (owner read/write/execute only)
   - /etc/eventstore/certs/ca: 700 (owner read/write/execute only)
4. All certificate files are owned by the eventstore user
5. CA certificate is automatically added to the system's trusted certificates

## IP Access List Module Usage Example

```
module "my_ip_access_list" {
  source = "./modules/ip_access_list"

  name = "my-access-list"
  vpc_id = aws_vpc.eventstore_vpc.id
  from_port = 2113
  to_port = 2113
  protocol = "tcp"
  addresses = [
    {
      cidr        = "134.56.254.123/32"
      description = "Yordis Prieto's IP Address"
    },
    {
      cidr        = "203.0.113.0/24"
      description = "Office Network"
    }
  ]
}
