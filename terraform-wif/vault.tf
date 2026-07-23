provider "vault" {}

data "vault_namespace" "current" {}

resource "vault_identity_oidc" "issuer" {
  issuer = var.public_oidc_issuer_url
}

resource "vault_identity_oidc_key" "secrets_sync" {
  name               = "${local.name_prefix}-key"
  algorithm          = "RS256"
  rotation_period    = 60 * 60 * 24
  verification_ttl   = 60 * 60 * 24
  allowed_client_ids = [local.aws_audience]
}

resource "vault_identity_oidc_role" "publish_key" {
  name = "${local.name_prefix}-key-publisher"
  key  = vault_identity_oidc_key.secrets_sync.name
}

resource "vault_activation_flags" "secrets_sync" {
  feature = "secrets-sync"
}

resource "vault_secrets_sync_aws_destination" "this" {
  name     = local.destination_name
  region   = var.aws_region
  role_arn = aws_iam_role.secrets_sync.arn

  identity_token_audience_wo         = local.aws_audience
  identity_token_audience_wo_version = 1
  identity_token_key_wo              = vault_identity_oidc_key.secrets_sync.name
  identity_token_key_wo_version      = 1
  identity_token_ttl                 = 60 * 60

  granularity          = "secret-path"
  secret_name_template = local.secret_name_template
  custom_tags          = local.common_tags

  depends_on = [
    vault_activation_flags.secrets_sync,
    vault_identity_oidc_role.publish_key,
    time_sleep.wait_for_iam,
  ]
}

resource "vault_mount" "kv" {
  path = local.kv_mount_path
  type = "kv-v2"
}

resource "vault_kv_secret_v2" "demo" {
  mount = vault_mount.kv.path
  name  = var.secret_name

  data_json = jsonencode({
    purpose = "non-sensitive WIF synchronization verification"
  })
}

resource "vault_secrets_sync_association" "demo" {
  name        = vault_secrets_sync_aws_destination.this.name
  type        = vault_secrets_sync_aws_destination.this.type
  mount       = vault_mount.kv.path
  secret_name = vault_kv_secret_v2.demo.name
}
