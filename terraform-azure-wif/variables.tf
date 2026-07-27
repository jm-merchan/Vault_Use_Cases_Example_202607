variable "azure_audience" {
  description = "Audience accepted by the Microsoft Entra federated identity credential."
  type        = string
  default     = "api://AzureADTokenExchange"
}

variable "azure_location" {
  description = "Azure region for the resource group and Key Vault."
  type        = string
  default     = "westeurope"
}

variable "azure_subscription_id" {
  description = "Azure subscription ID used by the AzureRM provider."
  type        = string
}

variable "name_prefix" {
  description = "Short prefix used to name the WIF PoC resources."
  type        = string
  default     = "mapfre-wif"
}

variable "public_oidc_issuer_url" {
  description = "Public HTTPS base URL of Vault used by Entra to retrieve OIDC metadata and JWKS."
  type        = string
  default     = "https://vault.jose-merchan.sbx.hashidemos.io"

  validation {
    condition     = startswith(var.public_oidc_issuer_url, "https://")
    error_message = "public_oidc_issuer_url must start with https://."
  }
}

variable "secret_name" {
  description = "Name of the demonstration secret in Vault."
  type        = string
  default     = "verification"
}
