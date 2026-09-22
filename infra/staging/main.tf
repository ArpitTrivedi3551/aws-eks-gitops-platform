module "network" {
  source = "../modules/network"

  name               = local.name
  cluster_name       = local.cluster_name
  azs                = var.azs
  admin_cidr         = var.admin_cidr
  single_nat_gateway = var.single_nat_gateway
  bastion_key_name   = var.bastion_key_name
  tags               = local.common_tags
}

module "database" {
  source = "../modules/database"

  name            = local.name
  vpc_id          = module.network.vpc_id
  data_subnet_ids = module.network.data_subnet_ids

  # 5432 reachable only from these SGs. Bastion now; the EKS node SG is added
  # here once the eks module exists so the app pods can reach the database.
  allowed_security_group_ids = [
    module.network.bastion_security_group_id,
  ]

  multi_az = true
  tags     = local.common_tags
}

module "eks" {
  source = "../modules/eks"

  name         = local.name
  cluster_name = local.cluster_name
  subnet_ids   = module.network.app_subnet_ids
  kms_key_arn  = module.database.kms_key_arn   # reuse the CMK for secret encryption
  admin_cidr   = var.admin_cidr                # restrict the public API endpoint
  tags         = local.common_tags
}

# Let EKS nodes/pods reach PostgreSQL. Placed at the root (not inside the
# database module) so database does not depend on eks -> no dependency cycle.
resource "aws_security_group_rule" "nodes_to_rds" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = module.database.rds_security_group_id
  source_security_group_id = module.eks.cluster_security_group_id
  description              = "PostgreSQL from EKS nodes/pods"
}