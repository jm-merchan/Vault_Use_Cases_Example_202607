data "azuread_client_config" "current" {}

data "azurerm_client_config" "current" {}

data "vault_namespace" "current" {}

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

  oidc_base_url = data.vault_namespace.current.id == "/" ? "${vault_identity_oidc.issuer.issuer}/v1/identity/oidc/secrets-sync" : "${vault_identity_oidc.issuer.issuer}/v1/${data.vault_namespace.current.id}identity/oidc/secrets-sync"

  namespace_segment = data.vault_namespace.current.id == "/" ? "root" : trimsuffix(data.vault_namespace.current.id, "/")
  expected_subject  = "secrets-sync:${local.namespace_segment}:azure-kv:${local.destination_name}"

  common_tags = {
    ManagedBy = "Terraform"
    Purpose   = "VaultSecretsSyncWIF"
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

resource "vault_identity_oidc" "issuer" {
  issuer = var.public_oidc_issuer_url
}

resource "vault_identity_oidc_key" "secrets_sync" {
  name               = "${var.name_prefix}-secrets-sync-key"
  algorithm          = "RS256"
  rotation_period    = 60 * 60 * 24
  verification_ttl   = 60 * 60 * 24
  allowed_client_ids = [var.azure_audience]
}

resource "vault_identity_oidc_role" "publish_key" {
  name = "${var.name_prefix}-key-publisher"
  key  = vault_identity_oidc_key.secrets_sync.name
}

resource "azuread_application_federated_identity_credential" "secrets_sync" {
  application_id = azuread_application.secrets_sync.id
  display_name   = "${var.name_prefix}-secrets-sync"
  audiences      = [var.azure_audience]
  issuer         = local.oidc_base_url
  subject        = local.expected_subject
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
    azuread_application_federated_identity_credential.secrets_sync,
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
    purpose = "Azure WIF Secrets Sync verification"
  })
}

resource "vault_secrets_sync_azure_destination" "wif" {
  name          = local.destination_name
  key_vault_uri = azurerm_key_vault.secrets_sync.vault_uri
  client_id     = azuread_application.secrets_sync.client_id
  tenant_id     = data.azurerm_client_config.current.tenant_id

  identity_token_audience_wo         = var.azure_audience
  identity_token_audience_wo_version = 1
  identity_token_key_wo              = vault_identity_oidc_key.secrets_sync.name
  identity_token_key_wo_version      = 1
  identity_token_ttl                 = 60 * 60

  granularity          = "secret-path"
  secret_name_template = local.secret_name_template
  custom_tags          = local.common_tags

  depends_on = [
    time_sleep.wait_for_entra,
    vault_activation_flags.secrets_sync,
    vault_identity_oidc_role.publish_key,
  ]
}

resource "vault_secrets_sync_association" "demo" {
  name        = vault_secrets_sync_azure_destination.wif.name
  type        = vault_secrets_sync_azure_destination.wif.type
  mount       = vault_mount.kv.path
  secret_name = vault_kv_secret_v2.demo.name
}
