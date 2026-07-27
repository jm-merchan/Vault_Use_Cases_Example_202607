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
  description = "Short prefix used to name the SPN PoC resources."
  type        = string
  default     = "mapfre-spn"
}

variable "secret_name" {
  description = "Name of the demonstration secret in Vault."
  type        = string
  default     = "verification"
}
