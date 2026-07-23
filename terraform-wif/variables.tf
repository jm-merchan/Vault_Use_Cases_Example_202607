variable "aws_audience" {
  description = "Audience claim for the WIF token. Leave empty to derive it from the issuer without its scheme."
  type        = string
  default     = ""
  nullable    = false
}

variable "aws_region" {
  description = "AWS region where Secrets Manager entries are synchronized."
  type        = string
  default     = "eu-central-1"
  nullable    = false
}

variable "public_oidc_issuer_url" {
  description = "Publicly reachable base URL of Vault that AWS uses for OIDC discovery and JWKS retrieval."
  type        = string
  default     = "https://vault.jose-merchan.sbx.hashidemos.io"
  nullable    = false

  validation {
    condition     = startswith(var.public_oidc_issuer_url, "https://")
    error_message = "public_oidc_issuer_url must start with https://."
  }
}

variable "secret_name" {
  description = "Name of the non-sensitive demo secret created in the tenant KV v2 mount."
  type        = string
  default     = "test"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9/_+=.@-]+$", "vault-${var.tenant_id}-${var.secret_name}"))
    error_message = "The rendered AWS Secrets Manager name contains unsupported characters."
  }
}

variable "tenant_id" {
  description = "Tenant identifier used to isolate the WIF, Vault, IAM, and Secrets Manager resources."
  type        = string
  default     = "mapfre-wif"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]([a-z0-9]*(-[a-z0-9]+)*)?$", var.tenant_id))
    error_message = "tenant_id must start with a lowercase letter and contain lowercase letters, digits, and single hyphens."
  }

  validation {
    condition     = length(var.tenant_id) <= 46
    error_message = "tenant_id must be 46 characters or fewer."
  }
}
