variable "application_domain" {
  type        = string
  description = "Application FQDN. Defaults to the administrative hostname with -apps appended to its first label."
  default     = null
  nullable    = true
}

locals {
  application_domain = var.application_domain != null ? var.application_domain : format(
    "%s-apps.%s",
    split(".", var.domain)[0],
    join(".", slice(split(".", var.domain), 1, length(split(".", var.domain))))
  )
}

resource "aws_route53_record" "application" {
  zone_id = var.zone_id
  name    = local.application_domain
  type    = "A"

  alias {
    name                   = aws_lb.vault_nlb["apps"].dns_name
    zone_id                = aws_lb.vault_nlb["apps"].zone_id
    evaluate_target_health = true
  }

}

output "vault_application_address" {
  description = "Public TLS endpoint distributing application requests across active and performance standby primary-cluster nodes."
  value       = "https://${local.application_domain}"
}

output "vault_application_target_group_arn" {
  description = "Target group used to inspect application endpoint routing and health."
  value       = aws_lb_target_group.nlb_api["apps"].arn
}

output "vault_admin_target_group_arn" {
  description = "Target group used to inspect active-only administrative routing."
  value       = aws_lb_target_group.nlb_api["admin"].arn
}
