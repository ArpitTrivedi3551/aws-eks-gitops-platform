output "vpc_id" {
  value = module.network.vpc_id
}
output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}
output "app_subnet_ids" {
  value = module.network.app_subnet_ids
}
output "data_subnet_ids" {
  value = module.network.data_subnet_ids
}
output "bastion_public_ip" {
  value = module.network.bastion_public_ip
}
output "nat_public_ips" {
  value = module.network.nat_public_ips
}


#db

output "rds_endpoint" {
  value = module.database.endpoint
}

output "db_secret_arn" {
  value = module.database.secret_arn
}

output "kms_key_arn" {
  value = module.database.kms_key_arn
}

#eks


output "cluster_name" {
  value = module.eks.cluster_name
}
output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}
output "cluster_security_group_id" {
  value = module.eks.cluster_security_group_id
}
output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}
output "node_role_arn" {
  value = module.eks.node_role_arn
}