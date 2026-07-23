output "application_client_id" {
  description = "Client ID of the SPN used by Vault Secrets Sync."
  value       = azuread_application.secrets_sync.client_id
}

output "destination_name" {
  description = "Name of the Vault Azure Key Vault destination."
  value       = vault_secrets_sync_azure_destination.spn.name
}

output "external_secret_name" {
  description = "Expected Azure Key Vault secret name."
  value       = replace(local.secret_name_template, "{{ .SecretBaseName }}", var.secret_name)
}

output "key_vault_name" {
  description = "Name of the Azure Key Vault receiving synchronized secrets."
  value       = azurerm_key_vault.secrets_sync.name
}

output "key_vault_uri" {
  description = "URI of the Azure Key Vault receiving synchronized secrets."
  value       = azurerm_key_vault.secrets_sync.vault_uri
}
