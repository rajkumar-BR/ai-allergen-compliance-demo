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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Remote state in S3 + DynamoDB state locking, so CI (see
  # .github/workflows/deploy.yml) and any teammate share one source of truth
  # and can never corrupt it with a concurrent apply. The bucket + lock table
  # are provisioned once by terraform/bootstrap/ (its own tiny, separate root
  # module/state - see that file for why) and never destroyed alongside this
  # stack.
  # The backend block cannot read var.aws_profile (backend config must be
  # static values - Terraform parses it before any variables are available),
  # and deliberately has no hardcoded "profile" here either, so it works
  # unchanged for anyone: it falls back to the standard AWS credential chain
  # (AWS_PROFILE / AWS_ACCESS_KEY_ID+AWS_SECRET_ACCESS_KEY env vars, or the
  # "default" profile) - set AWS_PROFILE in your shell (or GitHub Actions
  # secrets - see .github/workflows/deploy.yml) rather than editing this file.
  backend "s3" {
    bucket         = "ai-allergen-compliance-demo-tfstate-669232219904"
    key            = "ai-allergen-compliance-demo/terraform.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "ai-allergen-compliance-demo-tf-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
  # A non-empty var.aws_profile forces the AWS SDK's shared-config loader to
  # look up that EXACT named profile in ~/.aws/config, erroring out
  # ("failed to get shared config profile, <name>") if it isn't there - which
  # it never is in CI, where aws-actions/configure-aws-credentials exports
  # OIDC-derived credentials as plain AWS_ACCESS_KEY_ID/SECRET/SESSION_TOKEN
  # env vars, not a profile file. Passing `null` here (var.aws_profile's
  # default is "") skips profile lookup entirely and falls through to the
  # standard credential chain (env vars, then the "default" profile, then
  # instance/task role) - the outcome local users setting a real profile
  # name still want, and the only thing that works unmodified in CI too.
  profile = var.aws_profile != "" ? var.aws_profile : null
}
