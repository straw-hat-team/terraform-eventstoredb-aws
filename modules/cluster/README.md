# Cluster Module

This module provisions a cluster of EC2 instances for EventStoreDB/KurrentDB on AWS, supporting both single-node and multi-node topologies. It allows selection of AMI by name, instance sizing, storage configuration, and network/IP access control.

## Inputs

- `cluster_name`: Name of the cluster.
- `infrastructure_type`: "shared" or "dedicated".
- `network_id`: Subnet ID for the instances.
- `public_ip_access_list`: List of security group IDs.
- `server_version`: Version tag for the cluster.
- `instance_type`: EC2 instance type.
- `topology`: "single" or "multi" (3 nodes).
- `storage`: Object with `kind`, `size`, `iops`, `throughput`.
- `amis`: Map of AMI names to AMI IDs.
- `ami_name`: Name of the AMI to use from the map.

## Outputs

- `instance_ids`: List of EC2 instance IDs.
- `public_ips`: List of public IPs.
- `private_ips`: List of private IPs.

## Example Usage

```hcl
module "cluster" {
  source = "./modules/cluster"

  cluster_name           = "my-cluster"
  infrastructure_type    = "dedicated"
  network_id             = "subnet-xxxx"
  public_ip_access_list  = ["sg-xxxx"]
  server_version         = "24.10"
  instance_type          = "m8.large"
  topology               = "multi"
  storage = {
    kind       = "gp3"
    size       = 8
    iops       = 3000
    throughput = 125
  }
  amis = {
    "eventstore-24.10" = "ami-123456"
    "eventstore-23.10" = "ami-654321"
  }
  ami_name = "eventstore-24.10"
} 