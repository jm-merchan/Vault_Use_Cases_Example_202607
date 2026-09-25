resource "aws_security_group" "alb" {
  name        = "mapfre-vm-aap-alb"
  description = "AAP public TLS endpoint and OIDC discovery"
  vpc_id      = var.vpc_id
}

resource "aws_security_group" "vm" {
  name        = "mapfre-vm-aap-node"
  description = "Dedicated AAP VM; SSH from operator and HTTPS from ALB"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "public_tls" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_aap" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.vm.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "aap_tls" {
  security_group_id            = aws_security_group.vm.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "vm_outbound" {
  security_group_id = aws_security_group.vm.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "aap" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_ids[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.vm.id]
  key_name                    = var.key_name
  user_data                   = templatefile("${path.module}/bootstrap.sh.tftpl", { domain = var.domain })
  user_data_replace_on_change = false

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 150
    iops        = 3000
    throughput  = 125
  }

  tags = { Name = "mapfre-vm-aap" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_acm_certificate" "aap" {
  domain_name       = var.domain
  validation_method = "DNS"
}

resource "aws_route53_record" "validation" {
  for_each = { for option in aws_acm_certificate.aap.domain_validation_options : option.domain_name => option }
  zone_id  = var.zone_id
  name     = each.value.resource_record_name
  type     = each.value.resource_record_type
  records  = [each.value.resource_record_value]
  ttl      = 60
}

resource "aws_acm_certificate_validation" "aap" {
  certificate_arn         = aws_acm_certificate.aap.arn
  validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]
}

resource "aws_lb" "aap" {
  name               = "mapfre-vm-aap"
  load_balancer_type = "application"
  subnets            = var.subnet_ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "aap" {
  name                 = "mapfre-vm-aap"
  port                 = 443
  protocol             = "HTTPS"
  vpc_id               = var.vpc_id
  deregistration_delay = 10
  health_check {
    protocol            = "HTTPS"
    path                = "/api/controller/v2/ping/"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group_attachment" "aap" {
  target_group_arn = aws_lb_target_group.aap.arn
  target_id        = aws_instance.aap.id
  port             = 443
}

resource "aws_lb_listener" "aap" {
  load_balancer_arn = aws_lb.aap.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.aap.certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.aap.arn
  }
}

resource "aws_route53_record" "aap" {
  zone_id = var.zone_id
  name    = var.domain
  type    = "A"
  alias {
    name                   = aws_lb.aap.dns_name
    zone_id                = aws_lb.aap.zone_id
    evaluate_target_health = false
  }
}
