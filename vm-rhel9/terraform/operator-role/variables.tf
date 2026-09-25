variable "aws_region" {
  description = "AWS region containing the Secrets Manager destination."
  type        = string
  default     = "eu-central-1"
}

variable "destination_name" {
  description = "Name of the Vault AWS Secrets Manager synchronization destination."
  type        = string
  default     = "aws-sm-operator-role"
}

variable "sync_role_name" {
  description = "Name of the IAM role assumed by Vault Secrets Sync."
  type        = string
  default     = "mapfre-vm-operator-role"
}

variable "vault_irsa_role_name" {
  description = "IAM role attached to the Vault EC2 instance profile."
  type        = string
  default     = "mapfre-vm-vault"
}
