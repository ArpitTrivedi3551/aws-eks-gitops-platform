output "vpc_id" {
  value = aws_vpc.this.id
}
output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}
output "app_subnet_ids" {
  value = aws_subnet.app[*].id
}
output "data_subnet_ids" {
  value = aws_subnet.data[*].id
}
output "alb_security_group_id" {
  value = aws_security_group.alb.id
}
output "bastion_security_group_id" {
  value = aws_security_group.bastion.id
}
output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}
output "nat_public_ips" {
  value = aws_eip.nat[*].public_ip
}
output "azs" {
  value = var.azs
}
