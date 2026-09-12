# One-time bootstrap for the main config's remote state backend.
#
# This creates the S3 bucket (versioned + encrypted, state history recoverable)
# and the DynamoDB lock table (S3 native state locking, which superseded the
# old DynamoDB-table approach, is not yet available in every account/region
# combination, so this project uses the classic, universally-supported
# S3 + DynamoDB pattern) that the main config in ../ points its `backend "s3"`
# block at.
#
# Deliberately its OWN tiny root module with its OWN local state, kept
# separate from the main config: the classic bootstrapping problem is that a
# backend's storage can't sanely live inside the state it stores. Run this
# once, then configure ../providers.tf's backend block with the outputs
# below and run `terraform init -migrate-state` in ../.
#
# Nothing here should ever need to change day-to-day, so a second local state
# file for this one-time job is a fair trade against the alternative (no
# remote state at all, or a fragile self-referential setup).

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "ap-southeast-2"
}

variable "aws_profile" {
  type    = string
  default = "default"
}

variable "bucket_name" {
  description = "Globally-unique S3 bucket name for Terraform state. Defaults to a name derived from the account id so it never collides with another account's bucket of the same base name."
  type        = string
  default     = ""
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = var.bucket_name != "" ? var.bucket_name : "ai-allergen-compliance-demo-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  # Never force_destroy this one - it holds the state history for every
  # other stack. Deleting it is a deliberate, manual, separate decision.
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
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = "ai-allergen-compliance-demo-tf-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "bucket_name" {
  value = aws_s3_bucket.tfstate.bucket
}

output "lock_table_name" {
  value = aws_dynamodb_table.tf_lock.name
}

output "backend_config_snippet" {
  value = <<-EOT
    backend "s3" {
      bucket         = "${aws_s3_bucket.tfstate.bucket}"
      key            = "ai-allergen-compliance-demo/terraform.tfstate"
      region         = "${var.aws_region}"
      dynamodb_table = "${aws_dynamodb_table.tf_lock.name}"
      encrypt        = true
    }
  EOT
}
