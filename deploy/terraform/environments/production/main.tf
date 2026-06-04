# =============================================================================
# Production Environment
# HA: multi-AZ RDS, read replica, 3+ tasks, autoscaling
# =============================================================================

terraform {
  required_version = ">= 1.7.0"

  backend "s3" {
    bucket         = "core-wallet-tfstate"
    key            = "production/terraform.tfstate"
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
      Environment = "production"
      ManagedBy   = "terraform"
    }
  }
}

variable "image_tag" {
  description = "Container image tag (semver from git tag)"
  type        = string
}

module "stack" {
  source = "../../"

  project     = "core-wallet"
  environment = "production"
  aws_region  = "ap-southeast-1"
  image_tag   = var.image_tag
  image_owner = "hoale" # TODO: replace with your GitHub org/user

  # Database — production-grade
  db_instance_class        = "db.r6g.large" # 2 vCPU, 16 GB RAM
  db_allocated_storage     = 100
  db_max_allocated_storage = 500
  db_multi_az              = true # synchronous standby in another AZ
  db_read_replica          = true # async replica for lag-tolerant reads

  # ECS — production sizing (targets 2000 TPS sustained)
  wallet_service_cpu           = 1024 # 1 vCPU
  wallet_service_memory        = 2048 # 2 GB
  wallet_service_desired_count = 3    # min 3, autoscales to 10
  pgbouncer_cpu                = 256
  pgbouncer_memory             = 512
}

output "alb_dns_name" {
  value = module.stack.alb_dns_name
}

output "rds_endpoint" {
  value     = module.stack.rds_endpoint
  sensitive = true
}

output "rds_read_endpoint" {
  value     = module.stack.rds_read_endpoint
  sensitive = true
}
