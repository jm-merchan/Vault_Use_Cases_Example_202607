provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

data "tls_certificate" "issuer" {
  url          = var.public_oidc_issuer_url
  verify_chain = false
}

locals {
  oidc_base_url         = data.vault_namespace.current.id == "/" ? "${vault_identity_oidc.issuer.issuer}/v1/identity/oidc/secrets-sync" : "${vault_identity_oidc.issuer.issuer}/v1/${data.vault_namespace.current.id}identity/oidc/secrets-sync"
  oidc_issuer_no_scheme = replace(local.oidc_base_url, "https://", "")
  aws_audience          = var.aws_audience != "" ? var.aws_audience : local.oidc_issuer_no_scheme

  name_prefix          = "${var.tenant_id}-secrets-sync"
  destination_name     = "${var.tenant_id}-aws-sm"
  kv_mount_path        = "${var.tenant_id}-kv"
  secret_name_template = "vault-${var.tenant_id}-{{ .SecretBaseName }}"
  secret_prefix        = "vault-${var.tenant_id}-"

  namespace_segment = data.vault_namespace.current.id == "/" ? "root" : trimsuffix(data.vault_namespace.current.id, "/")
  expected_subject  = "secrets-sync:${local.namespace_segment}:aws-sm:${local.destination_name}"

  common_tags = {
    managed-by = "terraform-vault-secrets-sync-wif"
    tenant     = var.tenant_id
  }
}

resource "aws_iam_openid_connect_provider" "vault_secrets_sync" {
  url             = local.oidc_base_url
  client_id_list  = [local.aws_audience]
  thumbprint_list = [data.tls_certificate.issuer.certificates[0].sha1_fingerprint]

  tags = local.common_tags
}

resource "aws_iam_role" "secrets_sync" {
  name = "${local.name_prefix}-role"

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
            "${local.oidc_issuer_no_scheme}:aud" = local.aws_audience
            "${local.oidc_issuer_no_scheme}:sub" = local.expected_subject
          }
        }
      },
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "secrets_sync" {
  name = "${local.name_prefix}-policy"
  role = aws_iam_role.secrets_sync.id

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
          "secretsmanager:UntagResource",
          "secretsmanager:UpdateSecret",
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${local.secret_prefix}*"
      },
    ]
  })
}

resource "time_sleep" "wait_for_iam" {
  create_duration = "30s"

  depends_on = [
    aws_iam_openid_connect_provider.vault_secrets_sync,
    aws_iam_role.secrets_sync,
    aws_iam_role_policy.secrets_sync,
  ]
}
