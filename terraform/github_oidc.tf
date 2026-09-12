# GitHub Actions OIDC federation: lets the CI workflow
# (.github/workflows/deploy.yml) assume an IAM role and run
# terraform plan/apply + the Amplify deploy step with NO long-lived AWS
# access key stored in GitHub - the workflow exchanges GitHub's own OIDC
# token for temporary AWS credentials at run time.
#
# Trust is scoped to this one repo (var.github_repo) and, for the apply-
# capable subject, to pushes on `main` only - a workflow run from a fork or a
# feature-branch PR can plan but never assume the apply-capable path (see the
# two distinct `sub` conditions below).
#
# Permission scope is broad within the account (not narrowed to per-resource
# ARNs for every service - IAM/Lambda/API Gateway/Amplify are painful to
# scope tightly and this is a demo, not a shared production account) but the
# BLAST RADIUS is bounded by trust: only a workflow run actually triggered
# from github.com/${var.github_repo} can ever obtain these credentials at
# all, and only from the `main` branch for the mutating actions.

variable "github_repo" {
  description = "GitHub \"owner/repo\" this OIDC role trusts (e.g. rajkumar-BR/ai-allergen-compliance-demo)."
  type        = string
  default     = "rajkumar-BR/ai-allergen-compliance-demo"
}

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]

  tags = local.common_tags
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Any ref in this repo can assume the role (so a PR workflow can run
    # `terraform plan`); the workflow itself only ever runs `apply` when
    # triggered by a push to main (see deploy.yml's job-level `if:`), so a
    # feature-branch run assuming this role still can't mutate anything.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions_deploy" {
  name               = "${local.name_prefix}-github-actions-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "github_actions_deploy_permissions" {
  statement {
    sid    = "TerraformStateBackend"
    effect = "Allow"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::ai-allergen-compliance-demo-tfstate-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::ai-allergen-compliance-demo-tfstate-${data.aws_caller_identity.current.account_id}/*",
    ]
  }
  statement {
    sid       = "TerraformStateLock"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = ["arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/ai-allergen-compliance-demo-tf-lock"]
  }
  statement {
    sid    = "StackManagement"
    effect = "Allow"
    actions = [
      "lambda:*",
      "apigateway:*",
      "dynamodb:*",
      "s3:*",
      "secretsmanager:*",
      "amplify:*",
      "logs:*",
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole",
      "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:GetPolicyVersion",
      "iam:ListPolicyVersions", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies", "iam:PassRole",
      "iam:CreateOpenIDConnectProvider", "iam:GetOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "github_actions_deploy_permissions" {
  name   = "${local.name_prefix}-github-actions-deploy-permissions"
  policy = data.aws_iam_policy_document.github_actions_deploy_permissions.json
}

resource "aws_iam_role_policy_attachment" "github_actions_deploy_permissions_attach" {
  role       = aws_iam_role.github_actions_deploy.name
  policy_arn = aws_iam_policy.github_actions_deploy_permissions.arn
}

output "github_actions_role_arn" {
  description = "Paste into the repo's GitHub Actions - referenced by .github/workflows/deploy.yml as AWS_ROLE_ARN."
  value       = aws_iam_role.github_actions_deploy.arn
}
