output "vpc_id" {
  value = aws_vpc.this.id
}

output "subnet_id" {
  value = aws_subnet.this.id
}

output "internet_gateway_id" {
  value = var.public ? aws_internet_gateway.this[0].id : null
}

output "route_table_id" {
  value = var.public ? aws_route_table.this[0].id : null
} 