locals {
  name         = "${var.project}-${var.environment}"
  cluster_name = "${local.name}-eks"
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
