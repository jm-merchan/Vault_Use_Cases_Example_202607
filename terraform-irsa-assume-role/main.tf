data "aws_caller_identity" "current" {}

data "aws_iam_role" "vault_irsa" {
  name = var.vault_irsa_role_name
}

data "aws_region" "current" {}

data "aws_iam_policy_document" "assume_role_trust" {
  statement {
    sid     = "TrustVaultIrsaRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_iam_role.vault_irsa.arn]
    }
  }
}

resource "aws_iam_role" "secrets_sync" {
  name               = var.sync_role_name
  description        = "Role assumed by Vault Secrets Sync using its initial IRSA session."
  assume_role_policy = data.aws_iam_policy_document.assume_role_trust.json

  tags = {
    ManagedBy = "Terraform"
    Purpose   = "VaultSecretsSyncIrsaAssumeRolePoC"
  }
}

data "aws_iam_policy_document" "secrets_manager" {
  statement {
    sid    = "ManageVaultSyncedSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:PutSecretValue",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:UpdateSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.secret_name_prefix}*",
    ]
  }
}

resource "aws_iam_role_policy" "secrets_manager" {
  name   = "vault-secrets-sync"
  role   = aws_iam_role.secrets_sync.id
  policy = data.aws_iam_policy_document.secrets_manager.json
}

resource "aws_iam_role_policy" "vault_irsa_assume_role" {
  name = "vault-secrets-sync-assume-role"
  role = data.aws_iam_role.vault_irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AssumeSecretsSyncRole"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.secrets_sync.arn
      },
    ]
  })
}

resource "time_sleep" "wait_for_iam" {
  create_duration = "30s"

  depends_on = [
    aws_iam_role_policy.secrets_manager,
    aws_iam_role_policy.vault_irsa_assume_role,
  ]
}

resource "vault_secrets_sync_config" "global" {
  disabled       = false
  queue_capacity = 500000
}

resource "vault_mount" "verification" {
  path = "irsa-assume-role-kv"
  type = "kv-v2"
}

resource "vault_kv_secret_v2" "verification" {
  mount = vault_mount.verification.path
  name  = "verification"

  data_json = jsonencode({
    purpose = "IRSA plus role_arn verification"
  })
}

resource "vault_secrets_sync_aws_destination" "irsa_assume_role" {
  name     = var.destination_name
  region   = data.aws_region.current.region
  role_arn = aws_iam_role.secrets_sync.arn

  secret_name_template = "${var.secret_name_prefix}{{ .SecretBaseName | lowercase }}"

  custom_tags = {
    ManagedBy = "HashiCorpVault"
    Purpose   = "IrsaAssumeRolePoC"
  }

  depends_on = [
    time_sleep.wait_for_iam,
    vault_secrets_sync_config.global,
  ]
}

resource "vault_secrets_sync_association" "verification" {
  name        = vault_secrets_sync_aws_destination.irsa_assume_role.name
  type        = vault_secrets_sync_aws_destination.irsa_assume_role.type
  mount       = vault_mount.verification.path
  secret_name = vault_kv_secret_v2.verification.name
}
