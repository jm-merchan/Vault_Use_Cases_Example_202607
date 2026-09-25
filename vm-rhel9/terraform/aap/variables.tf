variable "admin_cidr" {
  description = "Operator IPv4 /32 permitted to use SSH."
  type        = string
}

variable "ami_id" {
  description = "Pinned official RHEL 9 RHUI x86_64 AMI."
  type        = string
}

variable "domain" {
  description = "Public FQDN for AAP and its OIDC issuer."
  type        = string
}

variable "instance_type" {
  description = "Dedicated AAP growth VM with 8 vCPUs and 32 GiB RAM."
  type        = string
  default     = "m6i.2xlarge"
}

variable "key_name" {
  description = "Existing EC2 key pair used by the operator."
  type        = string
  default     = "mapfre-vm"
}

variable "region" {
  description = "AWS region of the Vault demonstration."
  type        = string
  default     = "eu-central-1"
}

variable "subnet_ids" {
  description = "Existing public subnets; preserve their recorded ordering."
  type        = list(string)
  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "The ALB requires at least two subnets in different zones."
  }
}

variable "vpc_id" {
  description = "Existing VPC containing the Vault VMs."
  type        = string
}

variable "zone_id" {
  description = "Existing public Route 53 hosted zone."
  type        = string
}
