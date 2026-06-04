# =============================================================================
# ECS Module — Fargate cluster + wallet-service (with PgBouncer sidecar) + ALB
# =============================================================================

variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "public_subnet_ids" { type = list(string) }
variable "tags" { type = map(string) }

# Images
variable "wallet_service_image" { type = string }
variable "outbox_relay_image" { type = string }
variable "pgbouncer_image" { type = string }

# Sizing
variable "wallet_service_cpu" { type = number }
variable "wallet_service_memory" { type = number }
variable "wallet_service_desired_count" { type = number }
variable "pgbouncer_cpu" { type = number }
variable "pgbouncer_memory" { type = number }

# Database
variable "db_endpoint" { type = string }
variable "db_read_endpoint" { type = string }
variable "db_port" { type = number }
variable "db_name" { type = string }
variable "db_secret_arn" { type = string }

# =============================================================================
# IAM — Task execution role + task role
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_iam_role" "ecs_execution" {
  name = "${var.name_prefix}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution_base" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "${var.name_prefix}-secrets-access"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.db_secret_arn]
    }]
  })
}

resource "aws_iam_role" "ecs_task" {
  name = "${var.name_prefix}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = var.tags
}

# =============================================================================
# CloudWatch Log Groups
# =============================================================================

resource "aws_cloudwatch_log_group" "wallet_service" {
  name              = "/ecs/${var.name_prefix}/wallet-service"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "pgbouncer" {
  name              = "/ecs/${var.name_prefix}/pgbouncer"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "outbox_relay" {
  name              = "/ecs/${var.name_prefix}/outbox-relay"
  retention_in_days = 30
  tags              = var.tags
}

# =============================================================================
# ECS Cluster
# =============================================================================

resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

# =============================================================================
# Security Groups
# =============================================================================

resource "aws_security_group" "alb" {
  name_prefix = "${var.name_prefix}-alb-"
  description = "ALB inbound from internet (HTTPS)"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS from internet"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP (redirect to HTTPS)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb-sg" })

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "ecs_service" {
  name_prefix = "${var.name_prefix}-ecs-"
  description = "ECS tasks inbound from ALB"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "HTTP from ALB"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-ecs-sg" })

  lifecycle { create_before_destroy = true }
}

# =============================================================================
# ALB
# =============================================================================

resource "aws_lb" "main" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = true

  tags = var.tags
}

resource "aws_lb_target_group" "wallet_service" {
  name        = "${var.name_prefix}-ws-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
    matcher             = "200"
  }

  tags = var.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# NOTE: HTTPS listener requires an ACM certificate. Uncomment and provide cert ARN.
# resource "aws_lb_listener" "https" {
#   load_balancer_arn = aws_lb.main.arn
#   port              = 443
#   protocol          = "HTTPS"
#   ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
#   certificate_arn   = var.acm_certificate_arn
#
#   default_action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.wallet_service.arn
#   }
# }

# Temporary HTTP forwarding (remove once HTTPS is configured)
resource "aws_lb_listener" "http_forward" {
  load_balancer_arn = aws_lb.main.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.wallet_service.arn
  }
}

# =============================================================================
# ECS Task Definition — wallet-service + PgBouncer sidecar
# =============================================================================

resource "aws_ecs_task_definition" "wallet_service" {
  family                   = "${var.name_prefix}-wallet-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.wallet_service_cpu + var.pgbouncer_cpu
  memory                   = var.wallet_service_memory + var.pgbouncer_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "wallet-service"
      image     = var.wallet_service_image
      essential = true

      portMappings = [{
        containerPort = 8080
        protocol      = "tcp"
      }]

      environment = [
        { name = "APP_ENV", value = "production" },
        { name = "GIN_MODE", value = "release" },
        { name = "HTTP_ADDR", value = ":8080" },
        # Connect to PgBouncer sidecar on localhost:6432
        { name = "DB_DSN", value = "postgres://wallet_app:PLACEHOLDER@localhost:6432/${var.db_name}?sslmode=disable" },
        { name = "DB_LOCK_TIMEOUT", value = "1500ms" },
        { name = "DB_STATEMENT_TIMEOUT", value = "2500ms" },
        { name = "HTTP_REQUEST_TIMEOUT", value = "10s" },
        { name = "DB_MAX_CONNS", value = "50" },
        { name = "DB_MIN_CONNS", value = "5" },
        { name = "OTEL_ENABLED", value = "true" },
        { name = "OTEL_SERVICE_NAME", value = "wallet-service" },
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "localhost:4317" },
        { name = "DB_TX_MAX_RETRIES", value = "2" },
      ]

      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = "${var.db_secret_arn}:password::"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.wallet_service.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "wallet"
        }
      }

      dependsOn = [{
        containerName = "pgbouncer"
        condition     = "HEALTHY"
      }]
    },
    {
      name      = "pgbouncer"
      image     = var.pgbouncer_image
      essential = true

      portMappings = [{
        containerPort = 6432
        protocol      = "tcp"
      }]

      environment = [
        { name = "DB_HOST", value = split(":", var.db_endpoint)[0] },
        { name = "DB_PORT", value = tostring(var.db_port) },
        { name = "DB_NAME", value = var.db_name },
        { name = "DB_USER", value = "wallet_app" },
        { name = "POOL_MODE", value = "transaction" },
        { name = "DEFAULT_POOL_SIZE", value = "16" },
        { name = "MAX_CLIENT_CONN", value = "200" },
        { name = "RESERVE_POOL_SIZE", value = "5" },
        { name = "SERVER_IDLE_TIMEOUT", value = "600" },
        { name = "MAX_PREPARED_STATEMENTS", value = "200" },
        { name = "AUTH_TYPE", value = "scram-sha-256" },
        { name = "IGNORE_STARTUP_PARAMETERS", value = "extra_float_digits,application_name,search_path" },
      ]

      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = "${var.db_secret_arn}:password::"
        }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "pg_isready -h 127.0.0.1 -p 6432 -U wallet_app || exit 1"]
        interval    = 10
        timeout     = 3
        retries     = 3
        startPeriod = 10
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.pgbouncer.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "pgbouncer"
        }
      }
    }
  ])

  tags = var.tags
}

# =============================================================================
# ECS Service — wallet-service
# =============================================================================

resource "aws_ecs_service" "wallet_service" {
  name            = "${var.name_prefix}-wallet-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.wallet_service.arn
  desired_count   = var.wallet_service_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs_service.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.wallet_service.arn
    container_name   = "wallet-service"
    container_port   = 8080
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  lifecycle {
    ignore_changes = [desired_count] # managed by autoscaling
  }

  tags = var.tags
}

# =============================================================================
# Auto Scaling — wallet-service
# =============================================================================

resource "aws_appautoscaling_target" "wallet_service" {
  max_capacity       = 10
  min_capacity       = var.wallet_service_desired_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.wallet_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "wallet_service_cpu" {
  name               = "${var.name_prefix}-ws-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.wallet_service.resource_id
  scalable_dimension = aws_appautoscaling_target.wallet_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.wallet_service.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 60.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

resource "aws_appautoscaling_policy" "wallet_service_requests" {
  name               = "${var.name_prefix}-ws-requests-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.wallet_service.resource_id
  scalable_dimension = aws_appautoscaling_target.wallet_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.wallet_service.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.wallet_service.arn_suffix}"
    }
    target_value       = 1000.0 # requests per target per minute
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "service_security_group_id" {
  value = aws_security_group.ecs_service.id
}
