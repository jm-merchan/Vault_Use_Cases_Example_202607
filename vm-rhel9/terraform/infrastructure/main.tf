terraform {
  required_version = ">= 1.14, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.name, ManagedBy = "Terraform", Purpose = "VaultRHEL9PoC" }
  }
}
variable "region" {
  type        = string
  description = "AWS region of the existing EKS VPC."
  default     = "eu-central-1"
}
variable "name" {
  type        = string
  description = "Unique prefix for this isolated VM deployment."
  default     = "mapfre-vm"
}
variable "vpc_id" {
  type        = string
  description = "Existing VPC with routing to Kubernetes workloads."
}
variable "subnet_ids" {
  type        = list(string)
  description = "Three public subnets in different availability zones."
  validation {
    condition     = length(var.subnet_ids) == 3
    error_message = "Provide exactly three subnets."
  }
}
variable "admin_cidr" {
  type        = string
  description = "Operator IPv4 address with /32 for SSH and direct API access."
}
variable "public_key" {
  type        = string
  description = "SSH public key; private key stays on the operator workstation."
}
variable "zone_id" {
  type        = string
  description = "Existing public Route 53 zone for DNS aliases and Let's Encrypt DNS-01 validation."
}
variable "domain" {
  type        = string
  description = "Administrative Vault VM public FQDN, routed to the active node. Also used for existing WIF discovery."
}
variable "vault_version" {
  type        = string
  description = "Pinned Enterprise Vault version installed on RHEL 9."
  default     = "2.1.1+ent"
}
data "aws_vpc" "existing" { id = var.vpc_id }
data "aws_subnet" "selected" {
  for_each = toset(var.subnet_ids)
  id       = each.key
}
data "aws_ami" "rhel9" {
  most_recent = true
  owners      = ["309956199498"]
  filter {
    name   = "name"
    values = ["RHEL-9.*_HVM-*-x86_64-*-Hourly2-GP3"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
locals {
  nodes = merge(
    { for i in range(6) : "primary-${i}" => { cluster = "primary", subnet = var.subnet_ids[i % 3] } },
    { for i in range(3) : "secondary-${i}" => { cluster = "secondary", subnet = var.subnet_ids[i % 3] } },
    { app = { cluster = "app", subnet = var.subnet_ids[0] } }
  )
}
resource "aws_kms_key" "seal" {
  description             = "${var.name} Vault auto-unseal"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}
resource "aws_kms_alias" "seal" {
  name          = "alias/${var.name}-seal"
  target_key_id = aws_kms_key.seal.key_id
}
resource "aws_iam_role" "vault" {
  name               = "${var.name}-vault"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }] })
}
resource "aws_iam_role_policy" "seal" {
  role   = aws_iam_role.vault.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"], Resource = aws_kms_key.seal.arn }] })
}
resource "aws_iam_instance_profile" "vault" {
  name = "${var.name}-vault"
  role = aws_iam_role.vault.name
}
resource "aws_key_pair" "operator" {
  key_name   = var.name
  public_key = var.public_key
}
resource "aws_security_group" "vm" {
  name   = "${var.name}-vm"
  vpc_id = var.vpc_id
  ingress {
    description = "Operator SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }
  ingress {
    description = "Operator API for bootstrap"
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }
  ingress {
    description = "Vault API from EKS VPC"
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.existing.cidr_block]
  }
  ingress {
    description     = "Vault TLS and replication through NLB"
    from_port       = 8200
    to_port         = 8201
    protocol        = "tcp"
    security_groups = [aws_security_group.nlb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_instance" "node" {
  for_each                    = local.nodes
  ami                         = data.aws_ami.rhel9.id
  instance_type               = "t3.medium"
  subnet_id                   = each.value.subnet
  associate_public_ip_address = true
  vpc_security_group_ids      = each.value.cluster == "app" ? [aws_security_group.vm.id] : [aws_security_group.vm.id, aws_security_group.cluster[each.value.cluster].id]
  key_name                    = aws_key_pair.operator.key_name
  iam_instance_profile        = each.value.cluster == "app" ? null : aws_iam_instance_profile.vault.name
  user_data                   = templatefile("${path.module}/../../scripts/cloud-init.sh.tftpl", { vault_version = var.vault_version })
  user_data_replace_on_change = false
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }
  tags       = { Name = "${var.name}-${each.key}", VaultCluster = each.value.cluster }
  depends_on = [aws_iam_role_policy.seal]
}
resource "aws_route53_record" "api" {
  zone_id = var.zone_id
  name    = var.domain
  type    = "A"
  alias {
    name                   = aws_lb.vault_nlb["admin"].dns_name
    zone_id                = aws_lb.vault_nlb["admin"].zone_id
    evaluate_target_health = true
  }
}
output "nodes" {
  description = "RHEL 9 nodes and network addresses."
  value       = { for k, v in aws_instance.node : k => { id = v.id, public_ip = v.public_ip, private_ip = v.private_ip, cluster = local.nodes[k].cluster, zone = data.aws_subnet.selected[local.nodes[k].subnet].availability_zone, api_fqdn = "${k}.${local.node_dns_suffix}", internal_fqdn = "${k}-internal.${local.node_dns_suffix}" } }
}
output "vault_address" {
  description = "Active-only administrative TLS endpoint for Vault and existing WIF discovery."
  value       = "https://${var.domain}"
}
output "kms_key_id" {
  description = "Auto-unseal key identifier."
  value       = aws_kms_key.seal.key_id
}
output "vault_role_name" {
  description = "EC2 role for local credential chain and role chaining scenarios."
  value       = aws_iam_role.vault.name
}
output "vault_role_arn" {
  description = "EC2 IAM role ARN."
  value       = aws_iam_role.vault.arn
}
output "security_group_id" {
  description = "VM group for restricted auxiliary-service ingress."
  value       = aws_security_group.vm.id
}

variable "eks_security_group_id" {
  type        = string
  description = "EKS control-plane security group; allow TokenReview from Vault VMs only."
}
resource "aws_vpc_security_group_ingress_rule" "eks_api_from_vault" {
  security_group_id            = var.eks_security_group_id
  referenced_security_group_id = aws_security_group.vm.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "Vault RHEL9 TokenReview and Kubernetes secrets engine"
}
