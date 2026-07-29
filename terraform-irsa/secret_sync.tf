terraform {
  required_version = ">= 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
  }
}

provider "aws" {}

provider "vault" {}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_iam_role" "vault_irsa" {
  name = var.vault_irsa_role_name
}

variable "vault_irsa_role_name" {
  description = "Name of the local AWS IAM role assumed by the Vault Kubernetes service account."
  type        = string
  default     = "vault-kms-auto-unseal"
}

resource "vault_secrets_sync_config" "global_config" {
  disabled       = false
  queue_capacity = 500000
}

resource "aws_iam_role_policy" "vault_secrets_sync" {
  name = "vault-secrets-sync-local"
  role = data.aws_iam_role.vault_irsa.id

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
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:vault_sync_*"
      },
    ]
  })
}

resource "vault_secrets_sync_aws_destination" "local_irsa" {
  depends_on = [
    aws_iam_role_policy.vault_secrets_sync,
  ]

  name                 = "aws-sm-irsa-local"
  region               = data.aws_region.current.region
  secret_name_template = "vault_sync_{{ .SecretBaseName | lowercase }}"

  custom_tags = {
    Managed_by = "HashiCorp Vault"
  }
}

resource "vault_mount" "verification" {
  path        = "sync-aws-irsa"
  type        = "kv-v2"
  description = "Independent KV source for the AWS IRSA Secrets Sync notebook."
}

resource "vault_kv_secret_v2" "verification" {
  mount = vault_mount.verification.path
  name  = "verification"

  data_json = jsonencode({
    scenario = "aws-irsa"
    message  = "Managed independently by 5_Secret_Sync_AWS_IRSA.ipynb"
  })
}

resource "vault_secrets_sync_association" "verification" {
  name        = vault_secrets_sync_aws_destination.local_irsa.name
  type        = vault_secrets_sync_aws_destination.local_irsa.type
  mount       = vault_mount.verification.path
  secret_name = vault_kv_secret_v2.verification.name
}

output "aws_account_id" {
  description = "AWS account managed by the local IRSA Secrets Sync destination."
  value       = data.aws_caller_identity.current.account_id
}

output "vault_irsa_role_arn" {
  description = "ARN of the local IRSA role used by Vault through the AWS credential chain."
  value       = data.aws_iam_role.vault_irsa.arn
}
