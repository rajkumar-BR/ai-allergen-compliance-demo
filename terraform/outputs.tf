output "menu_uploads_bucket" {
  value = aws_s3_bucket.menu_uploads.bucket
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.menu_items.name
}

output "amplify_app_id" {
  value = aws_amplify_app.frontend.id
}

output "amplify_default_domain" {
  description = "Base Amplify domain; the live frontend URL is https://<branch>.<this>."
  value       = aws_amplify_app.frontend.default_domain
}

output "frontend_url" {
  description = "The live frontend URL once the first manual deployment has completed (see DEPLOY_GUIDE.md)."
  value       = "https://${aws_amplify_branch.main.branch_name}.${aws_amplify_app.frontend.default_domain}"
}

output "next_steps" {
  value = <<-EOT
    1. terraform output menu_api_invoke_url -> paste into app/static/config.js as window.API_BASE_URL.
    2. Zip app/static/ and deploy it to Amplify (see DEPLOY_GUIDE.md for the exact
       `aws amplify create-deployment` / `start-deployment` commands) - Amplify has
       no connected git repository in this demo, so deploys are manual.
    3. Open frontend_url in a browser once the deployment finishes.
    4. Make sure Bedrock model access is granted for ${var.bedrock_model_id}
       in ${var.aws_region} (Bedrock console -> Model access) - without it,
       allergen extraction/translation silently falls back to the offline
       keyword-scan / Amazon Translate stubs instead of the LLM.
  EOT
}

output "knowledge_base_id" {
  value       = var.create_knowledge_base ? aws_bedrockagent_knowledge_base.peal[0].id : ""
  description = "Bedrock Knowledge Base ID for RAG retrieval"
}

output "knowledge_base_arn" {
  value       = var.create_knowledge_base ? aws_bedrockagent_knowledge_base.peal[0].arn : ""
  description = "Bedrock Knowledge Base ARN"
}

output "kb_docs_bucket" {
  value       = var.create_knowledge_base ? aws_s3_bucket.kb_docs[0].bucket : ""
  description = "S3 bucket containing PEAL reference documents"
}
