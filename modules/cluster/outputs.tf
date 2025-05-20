output "instance_ids" {
  value = aws_instance.cluster_node[*].id
}

output "public_ips" {
  value = aws_instance.cluster_node[*].public_ip
}

output "private_ips" {
  value = aws_instance.cluster_node[*].private_ip
} 