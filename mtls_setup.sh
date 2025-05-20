#!/bin/bash

# Create directory for certificates
mkdir -p certs
cd certs

# Generate CA private key and certificate
openssl genrsa -out ca-key.pem 2048
openssl req -new -x509 -nodes -days 365 -key ca-key.pem -out ca.pem -subj "/CN=EventStoreDB CA"

# Generate client private key
openssl genrsa -out client-key.pem 2048

# Generate client CSR
openssl req -new -key client-key.pem -out client.csr -subj "/CN=EventStoreDB Client"

# Sign client certificate with CA
openssl x509 -req -days 365 -in client.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out client.pem

# Set proper permissions
chmod 600 *.pem
chmod 644 ca.pem

echo "mTLS certificates generated successfully in the 'certs' directory:"
echo "- ca.pem: CA certificate"
echo "- client.pem: Client certificate"
echo "- client-key.pem: Client private key"
echo
echo "Please store these certificates securely and update your Terraform variables accordingly." 