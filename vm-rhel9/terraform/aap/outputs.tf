output "aap_address" {
  description = "AAP public TLS URL."
  value       = "https://${var.domain}"
}

output "instance_id" {
  description = "Dedicated AAP EC2 instance ID."
  value       = aws_instance.aap.id
}

output "private_ip" {
  description = "Private address of the AAP VM."
  value       = aws_instance.aap.private_ip
}

output "public_ip" {
  description = "SSH address restricted to the operator IP."
  value       = aws_instance.aap.public_ip
}

output "target_group_arn" {
  description = "ALB target group for readiness verification."
  value       = aws_lb_target_group.aap.arn
}
