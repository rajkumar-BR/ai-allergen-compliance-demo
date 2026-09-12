# AWS Amplify Hosting for the static frontend (app/static/*). No git
# repository is connected - this demo has no GitHub remote, so deployments
# are manual zip uploads via `aws amplify create-deployment` +
# `start-deployment` (see DEPLOY_GUIDE.md for the exact commands). All actual
# backend logic (DynamoDB, S3, Lambda, API Gateway, Bedrock, Secrets Manager)
# is provisioned by the rest of this Terraform config, exactly as before -
# only the frontend's hosting mechanism changes from "served by Flask" to
# "served by Amplify's CDN".

resource "aws_amplify_app" "frontend" {
  name     = "${local.name_prefix}-frontend"
  platform = "WEB"

  tags = local.common_tags
}

resource "aws_amplify_branch" "main" {
  app_id      = aws_amplify_app.frontend.id
  branch_name = "main"
  stage       = "PRODUCTION"

  tags = local.common_tags
}
