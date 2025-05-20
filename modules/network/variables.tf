variable "name" {
  description = "Name of the network (VPC)"
  type        = string
}

variable "cidr_block" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "172.28.0.0/16"
}

variable "public" {
  description = "Whether the network is public (true) or private (false)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Optional tags to apply to resources"
  type        = map(string)
  default     = {}
} 