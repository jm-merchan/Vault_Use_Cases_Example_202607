terraform {
  required_version = ">= 1.14, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "mapfre-vm-aap"
      ManagedBy = "Terraform"
      Purpose   = "VaultAAPIntegrationPoC"
    }
  }
}
