# =============================================================================
# RDS Module — PostgreSQL 17, encrypted, multi-AZ optional, read replica optional
# =============================================================================

variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "allowed_security_groups" { type = list(string) }
variable "tags" { type = map(string) }

variable "instance_class" {
  type    = string
  default = "db.r6g.large"
}

variable "allocated_storage" {
  type    = number
  default = 100
}

variable "max_allocated_storage" {
  type    = number
  default = 500
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "create_read_replica" {
  type    = bool
  default = false
}

variable "engine_version" {
  type    = string
  default = "17.2"
}

variable "database_name" {
  type    = string
  default = "wallet"
}

variable "backup_retention_period" {
  type    = number
  default = 7
}

# =============================================================================
# Secrets — master password + app role passwords
# =============================================================================

resource "random_password" "master" {
  length  = 32
  special = false
}

resource "random_password" "wallet_app" {
  length  = 32
  special = false
}

resource "random_password" "wallet_pii_ro" {
  length  = 32
  special = false
}

resource "random_password" "wallet_eod" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "db_master" {
  name        = "${var.name_prefix}/rds/master"
  description = "RDS master credentials"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "db_master" {
  secret_id = aws_secretsmanager_secret.db_master.id
  secret_string = jsonencode({
    username = "postgres"
    password = random_password.master.result
  })
}

resource "aws_secretsmanager_secret" "db_app" {
  name        = "${var.name_prefix}/rds/wallet-app"
  description = "wallet_app role credentials (service connection)"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "db_app" {
  secret_id = aws_secretsmanager_secret.db_app.id
  secret_string = jsonencode({
    username = "wallet_app"
    password = random_password.wallet_app.result
    dbname   = var.database_name
  })
}

resource "aws_secretsmanager_secret" "db_pii" {
  name        = "${var.name_prefix}/rds/wallet-pii-ro"
  description = "wallet_pii_ro role credentials (PII reads)"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "db_pii" {
  secret_id = aws_secretsmanager_secret.db_pii.id
  secret_string = jsonencode({
    username = "wallet_pii_ro"
    password = random_password.wallet_pii_ro.result
    dbname   = var.database_name
  })
}

resource "aws_secretsmanager_secret" "db_eod" {
  name        = "${var.name_prefix}/rds/wallet-eod"
  description = "wallet_eod role credentials (EOD batch)"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "db_eod" {
  secret_id = aws_secretsmanager_secret.db_eod.id
  secret_string = jsonencode({
    username = "wallet_eod"
    password = random_password.wallet_eod.result
    dbname   = var.database_name
  })
}

# =============================================================================
# Security Group
# =============================================================================

resource "aws_security_group" "rds" {
  name_prefix = "${var.name_prefix}-rds-"
  description = "RDS PostgreSQL inbound from ECS services"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-rds-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "rds_ingress" {
  count                    = length(var.allowed_security_groups)
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = var.allowed_security_groups[count.index]
  security_group_id        = aws_security_group.rds.id
}

resource "aws_security_group_rule" "rds_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.rds.id
}

# =============================================================================
# Subnet Group
# =============================================================================

resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-db-subnet"
  subnet_ids = var.private_subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-db-subnet" })
}

# =============================================================================
# Parameter Group (PostgreSQL 17 tuned for wallet workload)
# =============================================================================

resource "aws_db_parameter_group" "pg17" {
  name_prefix = "${var.name_prefix}-pg17-"
  family      = "postgres17"
  description = "Core Wallet PG17 parameters"

  # Match local dev postgresql.conf settings for the wallet workload
  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "500" # log slow queries > 500ms
  }
  parameter {
    name  = "idle_in_transaction_session_timeout"
    value = "30000" # 30s — kill idle-in-tx (shouldn't happen with pooler)
  }
  parameter {
    name  = "statement_timeout"
    value = "0" # SP sets per-TX via SET LOCAL; global=0 so EOD can run long
  }
  parameter {
    name  = "lock_timeout"
    value = "0" # ditto
  }
  parameter {
    name  = "random_page_cost"
    value = "1.1" # SSD
  }
  parameter {
    name  = "effective_cache_size"
    value = "{DBInstanceClassMemory*3/4/8192}" # 75% of instance memory
  }
  parameter {
    name  = "work_mem"
    value = "65536" # 64MB
  }
  parameter {
    name  = "maintenance_work_mem"
    value = "524288" # 512MB
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# RDS Instance (Primary)
# =============================================================================

resource "aws_db_instance" "primary" {
  identifier = "${var.name_prefix}-pg"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.database_name
  username = "postgres"
  password = random_password.master.result

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.pg17.name

  backup_retention_period = var.backup_retention_period
  backup_window           = "02:00-03:00" # UTC → 09:00-10:00 VN
  maintenance_window      = "sun:04:00-sun:05:00"

  # Performance Insights (free tier on r6g.large)
  performance_insights_enabled = true

  # Logging
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # Protection
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name_prefix}-final-snapshot"

  tags = merge(var.tags, { Name = "${var.name_prefix}-pg-primary" })
}

# =============================================================================
# Read Replica (optional — for lag-tolerant reads: account profiles + statements)
# =============================================================================

resource "aws_db_instance" "read_replica" {
  count = var.create_read_replica ? 1 : 0

  identifier          = "${var.name_prefix}-pg-read"
  replicate_source_db = aws_db_instance.primary.identifier

  instance_class = var.instance_class
  storage_type   = "gp3"

  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.pg17.name

  performance_insights_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-pg-read" })
}

# =============================================================================
# Outputs
# =============================================================================

output "endpoint" {
  value = aws_db_instance.primary.endpoint
}

output "read_endpoint" {
  value = var.create_read_replica ? aws_db_instance.read_replica[0].endpoint : ""
}

output "port" {
  value = aws_db_instance.primary.port
}

output "database_name" {
  value = var.database_name
}

output "security_group_id" {
  value = aws_security_group.rds.id
}

output "app_secret_arn" {
  value = aws_secretsmanager_secret.db_app.arn
}

output "pii_secret_arn" {
  value = aws_secretsmanager_secret.db_pii.arn
}

output "eod_secret_arn" {
  value = aws_secretsmanager_secret.db_eod.arn
}
