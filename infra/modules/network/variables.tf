variable "name" {
  description = "Name for all resources"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Azs for the subnet"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs, one per AZ"
  type        = list(string)
  default     = ["10.0.0.0/20", "10.0.16.0/20"]
}

variable "app_subnet_cidrs" {
  description = "Private application subnet CIDRs, one per AZ"
  type        = list(string)
  default     = ["10.0.32.0/20", "10.0.48.0/20"]
}

variable "data_subnet_cidrs" {
  description = "Private data subnet CIDR for RDS"
  type        = list(string)
  default     = ["10.0.64.0/20", "10.0.80.0/20"]
}

variable "single_nat_gateway" {
  description = "true = NAT Gateway shared by all AZs"
  type        = bool
  default     = true
}

variable "admin_cidr" {
  description = "CIDR allowed to SSH to the bastion"
  type        = string
  validation {
    condition     = var.admin_cidr != "0.0.0.0/0"
    error_message = "Not allowed"
  }
}

variable "bastion_instance_type" {
  description = "Instance type for the bastion host."
  type        = string
  default     = "t3.micro"
}

variable "bastion_key_name" {
  description = "EC2 key pair for SSH to the bastion."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
