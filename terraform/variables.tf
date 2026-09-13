variable "aws_region" {
  description = "AWS region to deploy into. Must be a region where Bedrock and Textract are both available."
  type        = string
  default     = "ap-southeast-2" # Sydney - closest Bedrock-enabled region to NZ at time of writing
}

variable "project_name" {
  description = "Short name used as a prefix for all resources."
  type        = string
  default     = "ai-allergen-compliance-demo"
}

variable "environment" {
  description = "Environment name tag (dev/test/prod)."
  type        = string
  default     = "dev"
}

variable "bedrock_model_id" {
  description = "Bedrock model ID used for allergen extraction + translation. Verify access/availability for this exact id in var.aws_region via `aws bedrock list-foundation-models` - cross-region inference profile ids are region-prefixed (e.g. apac./us./eu.)."
  type        = string
  default     = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "create_knowledge_base" {
  description = "OPT-IN: provision the Bedrock Knowledge Base for the compliance RAG layer (see bedrock_kb.tf). Off by default so the demo stack is unchanged."
  type        = bool
  default     = false
}

variable "knowledge_base_id" {
  description = "Bedrock Knowledge Base id the app retrieves from for compliance verification. Empty = app runs rules-only (with local keyword retrieval over bundled docs/)."
  type        = string
  default     = ""
}

variable "bedrock_embedding_model_arn" {
  description = "Bedrock embedding model ARN used to index the knowledge base. Default is Amazon Titan Text Embeddings v2 in the default region (ap-southeast-2); change if you deploy elsewhere."
  type        = string
  default     = "arn:aws:bedrock:ap-southeast-2::foundation-model/amazon.titan-embed-text-v2:0"
}

variable "aws_profile" {
  description = "AWS CLI named profile to use for credentials, e.g. \"personal\" for a local run. Leave as the empty-string default for CI or anywhere credentials come from plain AWS_* environment variables (GitHub Actions OIDC, an instance/task role) - a non-empty value here forces a literal named-profile lookup in ~/.aws/config, which fails outside a local dev machine."
  type        = string
  default     = ""
}

variable "app_admin_initial_password" {
  description = "Initial value seeded into the app_admin_password Secrets Manager secret (terraform/secrets.tf), which backs the app's /auth/login. Only used on first create - the app's own Change Password action rotates the live value afterwards, and terraform will not overwrite it on later applies (see secrets.tf's ignore_changes)."
  type        = string
  default     = "admin"
  sensitive   = true
}
