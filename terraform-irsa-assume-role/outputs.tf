output "aws_account_id" {
  description = "AWS account ID used for the IRSA and assumed-role validation."
  value       = data.aws_caller_identity.current.account_id
}

output "destination_name" {
  description = "Name of the configured Vault Secrets Sync destination."
  value       = vault_secrets_sync_aws_destination.irsa_assume_role.name
}

output "external_secret_name" {
  description = "Expected name of the synchronized AWS Secrets Manager secret."
  value       = "${var.secret_name_prefix}${vault_kv_secret_v2.verification.name}"
}

output "sync_role_arn" {
  description = "ARN assumed by Vault after obtaining its initial IRSA session."
  value       = aws_iam_role.secrets_sync.arn
}

output "vault_irsa_role_arn" {
  description = "ARN providing the initial AWS session to Vault."
  value       = data.aws_iam_role.vault_irsa.arn
}
