variable "name" {
  type        = string
  description = "Base name for resources (prefix)."
}

variable "environment" {
  type        = string
  description = "Environment name (dev/stage/prod)."
}

variable "region" {
  type        = string
  description = "AWS region"
  default     = null
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block (e.g. 10.0.0.0/16)"
}

variable "az_count" {
  type        = number
  description = "How many AZs to use (1..N). module will use first N available AZs"
  default     = 2
  validation {
    condition     = var.az_count >= 1
    error_message = "az_count must be >= 1"
  }
}

variable "subnets_per_az" {
  type        = object({
    public   = number
    private  = number
    isolated = number
  })
  description = "Number of subnets of each type PER AZ"
  default = {
    public   = 1
    private  = 1
    isolated = 0
  }
}

variable "subnet_mask_bits" {
  type        = number
  description = "How many bits to add to VPC mask when generating subnets. Common: for /16 -> /24 use 8"
  default     = 8
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Create NAT Gateways for private subnets"
  default     = true
}

variable "nat_gateway_per_az" {
  type        = bool
  description = "If true create one NAT GW per AZ, otherwise create 1 in first AZ and route others to it."
  default     = true
}

variable "enable_flow_logs" {
  type        = bool
  description = "Enable VPC Flow Logs"
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to created resources"
  default     = {}
}
