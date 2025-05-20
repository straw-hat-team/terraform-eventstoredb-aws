variable "name" {
  description = "The name of your IP Access list"
  type        = string
}

variable "addresses" {
  description = "List of objects with IP address/CIDR and description"
  type = list(object({
    cidr        = string
    description = string
  }))
}

variable "vpc_id" {
  description = "VPC ID to associate the security group with"
  type        = string
}

variable "from_port" {
  description = "Start port for ingress rule"
  type        = number
  default     = 0
}

variable "to_port" {
  description = "End port for ingress rule"
  type        = number
  default     = 65535
}

variable "protocol" {
  description = "Protocol for ingress rule (e.g., tcp, udp, -1 for all)"
  type        = string
  default     = "tcp"
} 