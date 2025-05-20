variable "cluster_name" { type = string }
variable "infrastructure_type" { type = string } # "shared" or "dedicated"
variable "network_id" { type = string }
variable "public_ip_access_list" { type = list(string) }
variable "server_version" { type = string }
variable "instance_type" { type = string }
variable "topology" { type = string } # "single" or "multi"
variable "storage" {
  type = object({
    kind       = string
    size       = number
    iops       = number
    throughput = number
  })
}
variable "amis" {
  description = "Map of AMI names to AMI IDs"
  type        = map(string)
}
variable "ami_name" {
  description = "Name of the AMI to use"
  type        = string
} 