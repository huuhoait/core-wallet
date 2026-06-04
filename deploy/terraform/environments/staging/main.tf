# =============================================================================
# Staging Environment
# Cost-optimized: single-AZ RDS, no read replica, 2 tasks min
# =============================================================================

terraform {
  required_version = ">= 1.7.0"

  backend "s3" {
    bucket         = "core-wallet-tfstate"
    key            = "staging/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "core-wallet-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region = "ap-southeast-1"

  default_tags {
    tags = {
      Project     = "core-wallet"
      Environment = "staging"
      ManagedBy   = "terraform"
    }
  }
}

variable "image_tag" {
  description = "Container image tag (git SHA from CD pipeline)"
  type        = string
}

module "stack" {
  source = "../../"

  project     = "core-wallet"
  environment = "staging"
  aws_region  = "ap-southeast-1"
  image_tag   = var.image_tag
  image_owner = "hoale" # TODO: replace with your GitHub org/user

  # Database — cost-optimized for staging
  db_instance_class        = "db.t4g.medium"
  db_allocated_storage     = 50
  db_max_allocated_storage = 100
  db_multi_az              = false
  db_read_replica          = false

  # ECS — minimal for staging
  wallet_service_cpu           = 256
  wallet_service_memory        = 512
  wallet_service_desired_count = 1
  pgbouncer_cpu                = 128
  pgbouncer_memory             = 256
}

output "alb_dns_name" {
  value = module.stack.alb_dns_name
}

output "rds_endpoint" {
  value = module.stack.rds_endpoint
}
