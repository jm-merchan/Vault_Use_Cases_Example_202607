terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }

    vault = {
      source = "hashicorp/vault"
    }
  }
}

provider "aws" {}

provider "vault" {}

data "aws_region" "current" {}

variable "aws_access_key_id" {
  description = "AWS access key ID used by the Vault Secrets Sync destination."
  type        = string
  sensitive   = true
}

variable "aws_secret_access_key" {
  description = "AWS secret access key used by the Vault Secrets Sync destination."
  type        = string
  sensitive   = true
}

variable "vault_public_address" {
  description = "Public HTTPS address that AWS uses to retrieve Vault's OIDC discovery document and JWKS."
  type        = string
  default     = "https://vault.jose-merchan.sbx.hashidemos.io"
}

locals {
  vault_secrets_sync_issuer   = "${trimsuffix(var.vault_public_address, "/")}/v1/identity/oidc/secrets-sync"
  vault_secrets_sync_audience = trimprefix(local.vault_secrets_sync_issuer, "https://")
  vault_secrets_sync_subject  = "secrets-sync::aws-sm:aws-sm-dest"
}

resource "vault_secrets_sync_config" "global_config" {
  disabled       = false
  queue_capacity = 500000
}

resource "aws_iam_policy" "secret_sync" {
  name        = "vault-secret-sync"
  description = "Allows Vault to synchronize managed secrets to AWS Secrets Manager."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:DeleteSecret",
          "secretsmanager:DescribeSecret",
          "secretsmanager:PutSecretValue",
          "secretsmanager:TagResource",
          "secretsmanager:UpdateSecret",
        ]
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.region}:*:secret:vault_sync_*"
      },
    ]
  })
}

resource "aws_iam_openid_connect_provider" "vault_secrets_sync" {
  url            = local.vault_secrets_sync_issuer
  client_id_list = [local.vault_secrets_sync_audience]
}

resource "aws_iam_role" "secret_sync" {
  name = "vault-secret-sync"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.vault_secrets_sync.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.vault_secrets_sync_audience}:aud" = local.vault_secrets_sync_audience
            "${local.vault_secrets_sync_audience}:sub" = local.vault_secrets_sync_subject
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "secret_sync" {
  role       = aws_iam_role.secret_sync.name
  policy_arn = aws_iam_policy.secret_sync.arn
}

resource "vault_secrets_sync_aws_destination" "aws" {
  name                 = "aws-sm-dest"
  access_key_id        = var.aws_access_key_id
  secret_access_key    = var.aws_secret_access_key
  region               = data.aws_region.current.region
  secret_name_template = "vault_sync_{{ .SecretBaseName | lowercase }}"

  custom_tags = {
    Managed_by = "HashiCorp Vault"
  }
}
