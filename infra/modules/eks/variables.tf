variable "name" {
  description = "Name prefix"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.31"
}

variable "subnet_ids" {
  description = "Private app subnet IDs for the control-plane ENIs and worker nodes."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "CMK ARN used to encrypt Kubernetes secrets "
  type        = string
}

variable "admin_cidr" {
  description = "CIDR allowed to reach the public Kubernetes API endpoint "
  type        = string
}

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}
variable "node_min_size" {
  type    = number
  default = 2
}
variable "node_max_size" {
  type    = number
  default = 3
}

variable "capacity_type" {
  description = "ON_DEMAND or SPOT. SPOT is cheaper but can be reclaimed."
  type        = string
  default     = "ON_DEMAND"
}

variable "tags" {
  type    = map(string)
  default = {}
}
