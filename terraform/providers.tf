terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Local state by default so `terraform destroy` has zero extra
  # dependencies for this demo. For a real multi-person team, uncomment
  # and point this at an S3 backend + DynamoDB lock table instead.
  # backend "s3" {
  #   bucket = "your-tfstate-bucket"
  #   key    = "ai-allergen-compliance-demo/terraform.tfstate"
  #   region = "ap-southeast-2"
  # }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}
