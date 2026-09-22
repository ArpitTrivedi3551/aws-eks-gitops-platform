variable "project" {
  description = "Project name"
  type        = string
  default     = "senior-devops"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "staging"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "azs" {
  description = "Availability zones"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "admin_cidr" {
  description = "public IP allowed to SSH the bastion."
  type        = string
}

variable "single_nat_gateway" {
  description = "Nat Gateway"
  type        = bool
  default     = true
}

variable "bastion_key_name" {
  description = "EC2 key pair name for SSH to the bastion"
  type        = string
  default     = null
}
