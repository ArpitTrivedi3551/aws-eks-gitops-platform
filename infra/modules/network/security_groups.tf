# ALB security group: the public entry point for user traffic.

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "Public HTTP/HTTPS into the load balancer"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.tags, { Name = "${var.name}-alb-sg" })
}

# Bastion security group: SSH only from the admin CIDR.

resource "aws_security_group" "bastion" {
  name        = "${var.name}-bastion-sg"
  description = "SSH to the bastion from the admin IP only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH from admin CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.tags, { Name = "${var.name}-bastion-sg" })
}
