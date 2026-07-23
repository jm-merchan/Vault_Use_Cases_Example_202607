data "azuread_client_config" "current" {}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  destination_name     = "${var.name_prefix}-azure-kv"
  key_vault_name       = "kv-${var.name_prefix}-${random_string.suffix.result}"
  kv_mount_path        = "${var.name_prefix}-kv"
  secret_name_template = "vault-${var.name_prefix}-{{ .SecretBaseName }}"

  common_tags = {
    ManagedBy = "Terraform"
    Purpose   = "VaultSecretsSyncSPN"
  }
}

resource "azurerm_resource_group" "secrets_sync" {
  name     = "${var.name_prefix}-secrets-sync-rg"
  location = var.azure_location
  tags     = local.common_tags
}

resource "azurerm_key_vault" "secrets_sync" {
  name                       = local.key_vault_name
  resource_group_name        = azurerm_resource_group.secrets_sync.name
  location                   = azurerm_resource_group.secrets_sync.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  tags                       = local.common_tags
}

resource "azuread_application" "secrets_sync" {
  display_name = "${var.name_prefix}-secrets-sync"
  owners       = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "secrets_sync" {
  client_id = azuread_application.secrets_sync.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_password" "secrets_sync" {
  application_id = azuread_application.secrets_sync.id
  display_name   = "vault-secrets-sync"
}

resource "azurerm_role_assignment" "secrets_sync" {
  scope                = azurerm_key_vault.secrets_sync.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azuread_service_principal.secrets_sync.object_id
}

resource "azurerm_role_assignment" "verification_reader" {
  scope                = azurerm_key_vault.secrets_sync.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "wait_for_entra" {
  create_duration = "60s"

  depends_on = [
    azuread_application_password.secrets_sync,
    azurerm_role_assignment.secrets_sync,
  ]
}

resource "vault_activation_flags" "secrets_sync" {
  feature = "secrets-sync"
}

resource "vault_mount" "kv" {
  path = local.kv_mount_path
  type = "kv-v2"
}

resource "vault_kv_secret_v2" "demo" {
  mount = vault_mount.kv.path
  name  = var.secret_name

  data_json = jsonencode({
    purpose = "Azure SPN Secrets Sync verification"
  })
}

resource "vault_secrets_sync_azure_destination" "spn" {
  name          = local.destination_name
  key_vault_uri = azurerm_key_vault.secrets_sync.vault_uri
  client_id     = azuread_application.secrets_sync.client_id
  client_secret = azuread_application_password.secrets_sync.value
  tenant_id     = data.azurerm_client_config.current.tenant_id

  granularity          = "secret-path"
  secret_name_template = local.secret_name_template
  custom_tags          = local.common_tags

  depends_on = [
    time_sleep.wait_for_entra,
    vault_activation_flags.secrets_sync,
  ]
}

resource "vault_secrets_sync_association" "demo" {
  name        = vault_secrets_sync_azure_destination.spn.name
  type        = vault_secrets_sync_azure_destination.spn.type
  mount       = vault_mount.kv.path
  secret_name = vault_kv_secret_v2.demo.name
}
