variable "aws_region" {
  description = "AWS region containing the Secrets Manager destination."
  type        = string
  default     = "eu-central-1"
}

variable "destination_name" {
  description = "Name of the Vault AWS Secrets Manager synchronization destination."
  type        = string
  default     = "aws-sm-irsa-assume-role"
}

variable "secret_name_prefix" {
  description = "Prefix restricting the Secrets Manager resources managed by the assumed role."
  type        = string
  default     = "vault_irsa_role_"
}

variable "sync_role_name" {
  description = "Name of the IAM role assumed by Vault Secrets Sync."
  type        = string
  default     = "vault-secrets-sync-irsa-assume-role"
}

variable "vault_irsa_role_name" {
  description = "Name of the IAM role associated with the Vault Kubernetes service account."
  type        = string
  default     = "vault-kms-auto-unseal"
}
