output "destination_name" {
  description = "Name of the Vault Azure Key Vault WIF destination."
  value       = vault_secrets_sync_azure_destination.wif.name
}

output "expected_subject" {
  description = "Subject configured in the Microsoft Entra federated identity credential."
  value       = local.expected_subject
}

output "external_secret_name" {
  description = "Expected Azure Key Vault secret name."
  value       = replace(local.secret_name_template, "{{ .SecretBaseName }}", var.secret_name)
}

output "federated_application_client_id" {
  description = "Client ID of the application configured for WIF."
  value       = azuread_application.secrets_sync.client_id
}

output "key_vault_name" {
  description = "Name of the Azure Key Vault receiving synchronized secrets."
  value       = azurerm_key_vault.secrets_sync.name
}

output "oidc_issuer" {
  description = "Vault Secrets Sync OIDC issuer trusted by Microsoft Entra."
  value       = local.oidc_base_url
}
