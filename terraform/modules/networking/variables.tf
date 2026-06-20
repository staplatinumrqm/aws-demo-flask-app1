variable "app_name" {
  description = "Name prefix for all resources"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zone names to spread subnets across"
  type        = list(string)
}

variable "container_port" {
  description = "Port the app container listens on (for the ECS security group)"
  type        = number
}
