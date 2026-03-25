# vulnerable.tf — Test fixture for Lacework IaC scanning (T-03, T-07)
# Contains intentional misconfigurations for testing purposes.
# DO NOT use in production.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# MISCONFIGURATION: S3 bucket with public access enabled
resource "aws_s3_bucket" "insecure_bucket" {
  bucket = "my-insecure-public-bucket"

  tags = {
    Environment = "test"
    Purpose     = "lacework-iac-scan-fixture"
  }
}

# MISCONFIGURATION: Public access block not configured (default allows public access)
resource "aws_s3_bucket_acl" "insecure_bucket_acl" {
  bucket = aws_s3_bucket.insecure_bucket.id
  acl    = "public-read"
}

# MISCONFIGURATION: No server-side encryption
resource "aws_s3_bucket_versioning" "insecure_versioning" {
  bucket = aws_s3_bucket.insecure_bucket.id
  versioning_configuration {
    status = "Disabled"
  }
}

# MISCONFIGURATION: Security group with unrestricted SSH access
resource "aws_security_group" "insecure_sg" {
  name        = "insecure-ssh-sg"
  description = "Intentionally insecure security group for testing"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Unrestricted SSH - CRITICAL
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# MISCONFIGURATION: IAM role with overly permissive policy
resource "aws_iam_role_policy" "insecure_policy" {
  name = "insecure-wildcard-policy"
  role = aws_iam_role.insecure_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "*"        # Wildcard actions - HIGH severity
        Resource = "*"        # Wildcard resources - HIGH severity
      }
    ]
  })
}

resource "aws_iam_role" "insecure_role" {
  name = "insecure-test-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}
