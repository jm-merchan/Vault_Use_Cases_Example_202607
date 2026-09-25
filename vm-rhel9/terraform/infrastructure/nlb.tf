# TCP listeners preserve client TLS (8200) and Vault-managed replication mTLS (8201).
locals {
  dns_suffix       = join(".", slice(split(".", var.domain), 1, length(split(".", var.domain))))
  secondary_domain = "vault-vm-secondary.${local.dns_suffix}"
  node_dns_suffix  = "vm-vault.${local.dns_suffix}"
  nlb_endpoints = {
    admin     = { cluster = "primary", apps = false }
    apps      = { cluster = "primary", apps = true }
    secondary = { cluster = "secondary", apps = false }
  }
  nlb_targets = merge([for endpoint, config in local.nlb_endpoints : {
    for node, spec in local.nodes : "${endpoint}-${node}" => { endpoint = endpoint, node = node } if spec.cluster == config.cluster
  }]...)
  nlb_listeners = merge([for endpoint, config in local.nlb_endpoints : {
    for port in(config.apps ? [443, 8200] : [443, 8200, 8201]) : "${endpoint}-${port}" => { endpoint = endpoint, port = port }
  }]...)
}
resource "aws_security_group" "nlb" {
  name   = "${var.name}-nlb"
  vpc_id = var.vpc_id
  dynamic "ingress" {
    for_each = toset([443, 8200])
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  ingress {
    description = "Replication clients in the demo VPC only"
    from_port   = 8201
    to_port     = 8201
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.existing.cidr_block]
  }
  egress {
    from_port   = 8200
    to_port     = 8201
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.existing.cidr_block]
  }
}
resource "aws_lb" "vault_nlb" {
  for_each                         = local.nlb_endpoints
  name                             = "${var.name}-${each.key}-nlb"
  load_balancer_type               = "network"
  internal                         = each.key == "secondary"
  subnets                          = var.subnet_ids
  security_groups                  = [aws_security_group.nlb.id, aws_security_group.nlb_replication_clients.id]
  enable_cross_zone_load_balancing = true
}
resource "aws_lb_target_group" "nlb_api" {
  for_each             = local.nlb_endpoints
  name                 = "${var.name}-${each.key}-tcp"
  port                 = 8200
  protocol             = "TCP"
  vpc_id               = var.vpc_id
  preserve_client_ip   = false
  deregistration_delay = 10
  health_check {
    protocol            = "HTTPS"
    port                = "8200"
    path                = each.value.apps ? "/v1/sys/health?perfstandbyok=true" : "/v1/sys/health"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}
resource "aws_lb_target_group" "nlb_replication" {
  for_each             = { for k, v in local.nlb_endpoints : k => v if !v.apps }
  name                 = "${var.name}-${each.key}-pr"
  port                 = 8201
  protocol             = "TCP"
  vpc_id               = var.vpc_id
  preserve_client_ip   = false
  deregistration_delay = 10
  health_check {
    protocol            = "HTTPS"
    port                = "8200"
    path                = "/v1/sys/health"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}
resource "aws_lb_target_group_attachment" "nlb_api" {
  for_each         = local.nlb_targets
  target_group_arn = aws_lb_target_group.nlb_api[each.value.endpoint].arn
  target_id        = aws_instance.node[each.value.node].id
  port             = 8200
}
resource "aws_lb_target_group_attachment" "nlb_replication" {
  for_each         = { for k, v in local.nlb_targets : k => v if v.endpoint != "apps" }
  target_group_arn = aws_lb_target_group.nlb_replication[each.value.endpoint].arn
  target_id        = aws_instance.node[each.value.node].id
  port             = 8201
}
resource "aws_lb_listener" "nlb" {
  for_each          = local.nlb_listeners
  load_balancer_arn = aws_lb.vault_nlb[each.value.endpoint].arn
  port              = each.value.port
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = each.value.port == 8201 ? aws_lb_target_group.nlb_replication[each.value.endpoint].arn : aws_lb_target_group.nlb_api[each.value.endpoint].arn
  }
}
resource "aws_route53_record" "secondary" {
  zone_id = var.zone_id
  name    = local.secondary_domain
  type    = "A"
  alias {
    name                   = aws_lb.vault_nlb["secondary"].dns_name
    zone_id                = aws_lb.vault_nlb["secondary"].zone_id
    evaluate_target_health = true
  }
}
resource "aws_route53_record" "node_api" {
  for_each = { for k, v in local.nodes : k => v if v.cluster != "app" }
  zone_id  = var.zone_id
  name     = "${each.key}.${local.node_dns_suffix}"
  type     = "A"
  ttl      = 60
  records  = [aws_instance.node[each.key].public_ip]
}
resource "aws_route53_record" "node_internal" {
  for_each = { for k, v in local.nodes : k => v if v.cluster != "app" }
  zone_id  = var.zone_id
  name     = "${each.key}-internal.${local.node_dns_suffix}"
  type     = "A"
  ttl      = 60
  records  = [aws_instance.node[each.key].private_ip]
}
output "vault_secondary_address" {
  description = "Private leader-only API for the PR secondary cluster."
  value       = "https://${local.secondary_domain}"
}
output "nlb" {
  description = "NLB names, DNS addresses and target groups for verification."
  value = { for k, v in aws_lb.vault_nlb : k => {
    arn                      = v.arn, dns_name = v.dns_name, api_target_group = aws_lb_target_group.nlb_api[k].arn,
    replication_target_group = try(aws_lb_target_group.nlb_replication[k].arn, null)
  } }
}

resource "aws_security_group" "nlb_replication_clients" {
  name   = "${var.name}-nlb-pr-clients"
  vpc_id = var.vpc_id
  ingress {
    description = "Secondary public egress addresses reaching the public primary NLB"
    from_port   = 8201
    to_port     = 8201
    protocol    = "tcp"
    cidr_blocks = [for k, v in aws_instance.node : "${v.public_ip}/32" if local.nodes[k].cluster == "secondary"]
  }
}

# Raft/request forwarding stays direct inside each cluster. PR between clusters must use NLB.
resource "aws_security_group" "cluster" {
  for_each = toset(["primary", "secondary"])
  name     = "${var.name}-${each.key}-cluster"
  vpc_id   = var.vpc_id
  ingress {
    description = "Internal cluster mTLS only"
    from_port   = 8201
    to_port     = 8201
    protocol    = "tcp"
    self        = true
  }
}
