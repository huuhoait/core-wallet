# =============================================================================
# Bootstrap — Create the S3 bucket + DynamoDB table for Terraform remote state.
# Run this ONCE manually before using the main Terraform configs.
#
# Usage:
#   cd deploy/terraform/bootstrap
#   terraform init
#   terraform apply
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

provider "aws" {
  region = "ap-southeast-1"
}

variable "project" {
  type    = string
  default = "core-wallet"
}

# =============================================================================
# S3 Bucket for state
# =============================================================================

resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project}-tfstate"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "terraform-state"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =============================================================================
# DynamoDB table for state locking
# =============================================================================

resource "aws_dynamodb_table" "tflock" {
  name         = "${var.project}-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "terraform-lock"
  }
}

# =============================================================================
# OIDC provider for GitHub Actions → AWS (keyless auth)
# =============================================================================

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# If the OIDC provider doesn't exist yet, create it (comment out data source above):
# resource "aws_iam_openid_connect_provider" "github" {
#   url             = "https://token.actions.githubusercontent.com"
#   client_id_list  = ["sts.amazonaws.com"]
#   thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
# }

resource "aws_iam_role" "github_deploy" {
  name = "${var.project}-github-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:*:*" # TODO: restrict to your repo
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name = "${var.project}-deploy-policy"
  role = aws_iam_role.github_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TerraformState"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
        ]
        Resource = [
          aws_s3_bucket.tfstate.arn,
          "${aws_s3_bucket.tfstate.arn}/*",
          aws_dynamodb_table.tflock.arn,
        ]
      },
      {
        Sid    = "ECSDeployment"
        Effect = "Allow"
        Action = [
          "ecs:*",
          "ec2:Describe*",
          "ec2:CreateSecurityGroup",
          "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:CreateTags",
          "ec2:DeleteTags",
          "elasticloadbalancing:*",
          "application-autoscaling:*",
          "logs:*",
          "iam:GetRole",
          "iam:PassRole",
          "iam:CreateRole",
          "iam:AttachRolePolicy",
          "iam:PutRolePolicy",
          "secretsmanager:GetSecretValue",
          "secretsmanager:CreateSecret",
          "secretsmanager:UpdateSecret",
          "secretsmanager:PutSecretValue",
        ]
        Resource = "*"
      },
      {
        Sid    = "RDS"
        Effect = "Allow"
        Action = [
          "rds:*",
        ]
        Resource = "*"
      },
      {
        Sid    = "VPC"
        Effect = "Allow"
        Action = [
          "ec2:CreateVpc",
          "ec2:DeleteVpc",
          "ec2:ModifyVpcAttribute",
          "ec2:CreateSubnet",
          "ec2:DeleteSubnet",
          "ec2:CreateInternetGateway",
          "ec2:DeleteInternetGateway",
          "ec2:AttachInternetGateway",
          "ec2:DetachInternetGateway",
          "ec2:CreateNatGateway",
          "ec2:DeleteNatGateway",
          "ec2:AllocateAddress",
          "ec2:ReleaseAddress",
          "ec2:CreateRouteTable",
          "ec2:DeleteRouteTable",
          "ec2:CreateRoute",
          "ec2:DeleteRoute",
          "ec2:AssociateRouteTable",
          "ec2:DisassociateRouteTable",
        ]
        Resource = "*"
      }
    ]
  })
}

# =============================================================================
# Outputs
# =============================================================================

output "state_bucket" {
  value = aws_s3_bucket.tfstate.id
}

output "lock_table" {
  value = aws_dynamodb_table.tflock.name
}

output "deploy_role_arn" {
  value       = aws_iam_role.github_deploy.arn
  description = "Set this as AWS_DEPLOY_ROLE_ARN in GitHub Actions secrets"
}
