output "aws_account_id" {
  description = "AWS account selected through Doormat."
  value       = data.aws_caller_identity.current.account_id
}

output "destination_name" {
  description = "Name of the Vault AWS Secrets Manager WIF destination."
  value       = vault_secrets_sync_aws_destination.this.name
}

output "expected_aws_secret_name" {
  description = "Expected AWS Secrets Manager name produced by the destination template."
  value       = replace(local.secret_name_template, "{{ .SecretBaseName }}", var.secret_name)
}

output "expected_token_subject" {
  description = "Subject claim required by the AWS role trust policy."
  value       = local.expected_subject
}

output "secrets_sync_oidc_discovery_url" {
  description = "Public Vault Secrets Sync OIDC discovery URL."
  value       = "${local.oidc_base_url}/.well-known/openid-configuration"
}

output "synced_secret_status" {
  description = "Synchronization status reported by the Vault association."
  value       = [for metadata in vault_secrets_sync_association.demo.metadata : metadata.sync_status]
}

output "wif_audience" {
  description = "Audience shared by the token, AWS OIDC provider, and role trust policy."
  value       = local.aws_audience
}

output "wif_role_arn" {
  description = "AWS role assumed by Vault through AssumeRoleWithWebIdentity."
  value       = aws_iam_role.secrets_sync.arn
}
