provider "vault" {}

data "vault_namespace" "current" {}

data "external" "existing_oidc_clients" {
  program = ["python3", "${path.module}/../../scripts/read_oidc_key_clients.py"]

  query = {
    key_name = local.oidc_key_name
  }
}

resource "vault_identity_oidc" "issuer" {
  issuer = var.public_oidc_issuer_url

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_identity_oidc_key" "secrets_sync" {
  name               = local.oidc_key_name
  algorithm          = "RS256"
  rotation_period    = 60 * 60 * 24
  verification_ttl   = 60 * 60 * 24
  allowed_client_ids = local.oidc_allowed_client_ids

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_identity_oidc_role" "publish_key" {
  name = "${local.name_prefix}-key-publisher"
  key  = vault_identity_oidc_key.secrets_sync.name
}

resource "vault_activation_flags" "secrets_sync" {
  feature = "secrets-sync"
}

# vault_secrets_sync_aws_destination omits identity_token_audience and
# identity_token_key on update. Vault then drops WIF and calls sts:AssumeRole
# with the instance profile credentials. This write always sends both fields.
removed {
  from = vault_secrets_sync_aws_destination.this

  lifecycle {
    destroy = false
  }
}

resource "vault_generic_endpoint" "aws_destination" {
  path         = "sys/sync/destinations/aws-sm/${local.destination_name}"
  disable_read = true

  data_json = jsonencode({
    role_arn                = aws_iam_role.secrets_sync.arn
    region                  = var.aws_region
    identity_token_audience = local.aws_audience
    identity_token_key      = vault_identity_oidc_key.secrets_sync.name
    identity_token_ttl      = 60 * 60
    granularity             = "secret-path"
    secret_name_template    = local.secret_name_template
    custom_tags             = local.common_tags
  })

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
  name        = local.destination_name
  type        = "aws-sm"
  mount       = vault_mount.kv.path
  secret_name = vault_kv_secret_v2.demo.name

  depends_on = [vault_generic_endpoint.aws_destination]
}
