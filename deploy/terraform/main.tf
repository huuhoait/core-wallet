# =============================================================================
# Core Wallet — Terraform Root Module
# AWS infrastructure: VPC + RDS PostgreSQL + ECS Fargate + ALB + PgBouncer
#
# Target: ap-southeast-1 (Singapore) — low latency to Vietnam
# =============================================================================

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

# =============================================================================
# Variables
# =============================================================================

variable "project" {
  description = "Project name prefix for all resources"
  type        = string
  default     = "core-wallet"
}

variable "environment" {
  description = "Environment name (staging, production)"
  type        = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "Environment must be staging or production."
  }
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "image_tag" {
  description = "Container image tag to deploy (git SHA or semver tag)"
  type        = string
}

variable "image_registry" {
  description = "Container image registry prefix"
  type        = string
  default     = "ghcr.io"
}

variable "image_owner" {
  description = "Container image owner/org (GHCR namespace)"
  type        = string
}

# Database
variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.r6g.large"
}

variable "db_allocated_storage" {
  description = "RDS initial storage (GB)"
  type        = number
  default     = 100
}

variable "db_max_allocated_storage" {
  description = "RDS max autoscaling storage (GB)"
  type        = number
  default     = 500
}

variable "db_multi_az" {
  description = "RDS multi-AZ deployment"
  type        = bool
  default     = false
}

variable "db_read_replica" {
  description = "Create a read replica"
  type        = bool
  default     = false
}

# ECS
variable "wallet_service_cpu" {
  description = "Fargate CPU units (1024 = 1 vCPU)"
  type        = number
  default     = 512
}

variable "wallet_service_memory" {
  description = "Fargate memory (MB)"
  type        = number
  default     = 1024
}

variable "wallet_service_desired_count" {
  description = "Number of wallet-service tasks"
  type        = number
  default     = 2
}

variable "pgbouncer_cpu" {
  description = "PgBouncer sidecar CPU units"
  type        = number
  default     = 256
}

variable "pgbouncer_memory" {
  description = "PgBouncer sidecar memory (MB)"
  type        = number
  default     = 256
}

# =============================================================================
# Locals
# =============================================================================

locals {
  name_prefix = "${var.project}-${var.environment}"
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  wallet_service_image = "${var.image_registry}/${var.image_owner}/core-wallet/wallet-service:${var.image_tag}"
  outbox_relay_image   = "${var.image_registry}/${var.image_owner}/core-wallet/outbox-relay:${var.image_tag}"
  pgbouncer_image      = "edoburu/pgbouncer:1.22.1-p0"
}

# =============================================================================
# Modules
# =============================================================================

module "vpc" {
  source = "./modules/vpc"

  name_prefix = local.name_prefix
  aws_region  = var.aws_region
  tags        = local.common_tags
}

module "rds" {
  source = "./modules/rds"

  name_prefix             = local.name_prefix
  vpc_id                  = module.vpc.vpc_id
  private_subnet_ids      = module.vpc.private_subnet_ids
  allowed_security_groups = [module.ecs.service_security_group_id]

  instance_class        = var.db_instance_class
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  multi_az              = var.db_multi_az
  create_read_replica   = var.db_read_replica

  tags = local.common_tags
}

module "ecs" {
  source = "./modules/ecs"

  name_prefix        = local.name_prefix
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  # Images
  wallet_service_image = local.wallet_service_image
  outbox_relay_image   = local.outbox_relay_image
  pgbouncer_image      = local.pgbouncer_image

  # Sizing
  wallet_service_cpu           = var.wallet_service_cpu
  wallet_service_memory        = var.wallet_service_memory
  wallet_service_desired_count = var.wallet_service_desired_count
  pgbouncer_cpu                = var.pgbouncer_cpu
  pgbouncer_memory             = var.pgbouncer_memory

  # Database
  db_endpoint      = module.rds.endpoint
  db_read_endpoint = module.rds.read_endpoint
  db_port          = module.rds.port
  db_name          = module.rds.database_name
  db_secret_arn    = module.rds.app_secret_arn

  tags = local.common_tags
}

# =============================================================================
# Outputs
# =============================================================================

output "alb_dns_name" {
  description = "ALB DNS name (wallet-service)"
  value       = module.ecs.alb_dns_name
}

output "rds_endpoint" {
  description = "RDS primary endpoint"
  value       = module.rds.endpoint
}

output "rds_read_endpoint" {
  description = "RDS read replica endpoint"
  value       = module.rds.read_endpoint
}
