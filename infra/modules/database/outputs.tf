output "endpoint" {
  description = "RDS endpoint host."
  value       = aws_db_instance.this.address
}
output "port" {
  value = 5432
}
output "db_name" {
  value = var.db_name
}
output "secret_arn" {
  description = "Secrets Manager ARN holding the DB credentials JSON."
  value       = aws_secretsmanager_secret.db.arn
}
output "kms_key_arn" {
  description = "CMK ARN (reused for EKS secret encryption)."
  value       = aws_kms_key.this.arn
}
output "rds_security_group_id" {
  value = aws_security_group.rds.id
}
