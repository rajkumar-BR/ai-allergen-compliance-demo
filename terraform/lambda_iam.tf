# ---------------------------------------------------------------------------
# Scoped IAM execution roles for every menu Lambda function (see lambda.tf).
#
# The whole point of this file is infrastructure-level least privilege: each
# function only gets the specific AWS actions its own handler code actually
# calls - e.g. readMenu physically cannot write (no PutItem/UpdateItem/
# DeleteItem/BatchWriteItem), and the allergen_api / reference_data
# analysis-only functions have no DynamoDB or S3 access at all. Each role also
# gets the minimal CloudWatch Logs baseline, scoped to its own log group ARN
# rather than "*".
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

locals {
  lambda_function_names = {
    read_menu      = "${local.name_prefix}-read-menu"
    edit_menu      = "${local.name_prefix}-edit-menu"
    auth           = "${local.name_prefix}-auth"
    dish_mutations = "${local.name_prefix}-dish-mutations"
    upload_menu    = "${local.name_prefix}-upload-menu"
    allergen_api   = "${local.name_prefix}-allergen-api"
    reference_data = "${local.name_prefix}-reference-data"
  }

  log_group_arn = {
    for key, name in local.lambda_function_names :
    key => "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${name}:*"
  }
}

# ---------------------------------------------------------------------------
# readMenu - read-only on the menu-items table.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "read_menu_exec" {
  name               = "${local.name_prefix}-read-menu-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "read_menu_permissions" {
  statement {
    sid       = "MenuItemsReadOnly"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
    resources = [aws_dynamodb_table.menu_items.arn, "${aws_dynamodb_table.menu_items.arn}/index/*"]
  }
  statement {
    sid       = "ReadMenuLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.log_group_arn["read_menu"]]
  }
}

resource "aws_iam_policy" "read_menu_permissions" {
  name   = "${local.name_prefix}-read-menu-permissions"
  policy = data.aws_iam_policy_document.read_menu_permissions.json
}

resource "aws_iam_role_policy_attachment" "read_menu_permissions_attach" {
  role       = aws_iam_role.read_menu_exec.name
  policy_arn = aws_iam_policy.read_menu_permissions.arn
}

# ---------------------------------------------------------------------------
# editMenu - UpdateItem only on the menu-items table. Auth is now enforced
# inside the handler itself (services/auth_service.is_authorized), which only
# compares a bearer token string - it never reads the Secrets Manager
# password - so this role needs no Secrets Manager permission.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "edit_menu_exec" {
  name               = "${local.name_prefix}-edit-menu-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "edit_menu_permissions" {
  statement {
    sid       = "MenuItemsUpdateOnly"
    effect    = "Allow"
    actions   = ["dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.menu_items.arn]
  }
  statement {
    sid       = "EditMenuLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.log_group_arn["edit_menu"]]
  }
}

resource "aws_iam_policy" "edit_menu_permissions" {
  name   = "${local.name_prefix}-edit-menu-permissions"
  policy = data.aws_iam_policy_document.edit_menu_permissions.json
}

resource "aws_iam_role_policy_attachment" "edit_menu_permissions_attach" {
  role       = aws_iam_role.edit_menu_exec.name
  policy_arn = aws_iam_policy.edit_menu_permissions.arn
}

# ---------------------------------------------------------------------------
# auth - only touches the admin-password secret, no DynamoDB/S3 at all.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "auth_exec" {
  name               = "${local.name_prefix}-auth-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "auth_permissions" {
  statement {
    sid       = "AdminPasswordSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"]
    resources = [aws_secretsmanager_secret.app_admin_password.arn]
  }
  statement {
    sid       = "AuthLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.log_group_arn["auth"]]
  }
}

resource "aws_iam_policy" "auth_permissions" {
  name   = "${local.name_prefix}-auth-permissions"
  policy = data.aws_iam_policy_document.auth_permissions.json
}

resource "aws_iam_role_policy_attachment" "auth_permissions_attach" {
  role       = aws_iam_role.auth_exec.name
  policy_arn = aws_iam_policy.auth_permissions.arn
}

# ---------------------------------------------------------------------------
# dish_mutations - create/delete dishes and run the analyze+translate
# pipeline: DynamoDB write actions + Bedrock + Translate fallback. No S3
# (upload_menu is the only function that touches raw files) and no Secrets
# Manager (auth is a bearer-token compare, same as editMenu).
# ---------------------------------------------------------------------------
resource "aws_iam_role" "dish_mutations_exec" {
  name               = "${local.name_prefix}-dish-mutations-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "dish_mutations_permissions" {
  statement {
    sid    = "MenuItemsWrite"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:Query",
    ]
    resources = [aws_dynamodb_table.menu_items.arn]
  }
  statement {
    sid       = "BedrockInvoke"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = ["*"]
  }
  statement {
    sid       = "TranslateFallback"
    effect    = "Allow"
    actions   = ["translate:TranslateText"]
    resources = ["*"]
  }
  statement {
    sid       = "DishMutationsLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.log_group_arn["dish_mutations"]]
  }
}

resource "aws_iam_policy" "dish_mutations_permissions" {
  name   = "${local.name_prefix}-dish-mutations-permissions"
  policy = data.aws_iam_policy_document.dish_mutations_permissions.json
}

resource "aws_iam_role_policy_attachment" "dish_mutations_permissions_attach" {
  role       = aws_iam_role.dish_mutations_exec.name
  policy_arn = aws_iam_policy.dish_mutations_permissions.arn
}

# ---------------------------------------------------------------------------
# upload_menu - the only function that touches raw uploaded files: S3 +
# Textract, plus the same DynamoDB write + Bedrock/Translate access as
# dish_mutations (it runs the same pipeline per parsed dish).
# ---------------------------------------------------------------------------
resource "aws_iam_role" "upload_menu_exec" {
  name               = "${local.name_prefix}-upload-menu-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "upload_menu_permissions" {
  statement {
    sid       = "MenuUploadsBucket"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.menu_uploads.arn}/*"]
  }
  statement {
    sid       = "TextractOcr"
    effect    = "Allow"
    actions   = ["textract:DetectDocumentText", "textract:AnalyzeDocument"]
    resources = ["*"]
  }
  statement {
    sid       = "MenuItemsPut"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.menu_items.arn]
  }
  statement {
    sid       = "BedrockInvoke"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = ["*"]
  }
  statement {
    sid       = "TranslateFallback"
    effect    = "Allow"
    actions   = ["translate:TranslateText"]
    resources = ["*"]
  }
  statement {
    sid       = "UploadMenuLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.log_group_arn["upload_menu"]]
  }
}

resource "aws_iam_policy" "upload_menu_permissions" {
  name   = "${local.name_prefix}-upload-menu-permissions"
  policy = data.aws_iam_policy_document.upload_menu_permissions.json
}

resource "aws_iam_role_policy_attachment" "upload_menu_permissions_attach" {
  role       = aws_iam_role.upload_menu_exec.name
  policy_arn = aws_iam_policy.upload_menu_permissions.arn
}

# ---------------------------------------------------------------------------
# allergen_api - pure analysis, no persistence: Bedrock only.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "allergen_api_exec" {
  name               = "${local.name_prefix}-allergen-api-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "allergen_api_permissions" {
  statement {
    sid       = "BedrockInvoke"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = ["*"]
  }
  statement {
    sid       = "AllergenApiLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.log_group_arn["allergen_api"]]
  }
}

resource "aws_iam_policy" "allergen_api_permissions" {
  name   = "${local.name_prefix}-allergen-api-permissions"
  policy = data.aws_iam_policy_document.allergen_api_permissions.json
}

resource "aws_iam_role_policy_attachment" "allergen_api_permissions_attach" {
  role       = aws_iam_role.allergen_api_exec.name
  policy_arn = aws_iam_policy.allergen_api_permissions.arn
}

# ---------------------------------------------------------------------------
# reference_data - static/near-static GETs, no AWS resource access beyond logs.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "reference_data_exec" {
  name               = "${local.name_prefix}-reference-data-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "reference_data_permissions" {
  statement {
    sid       = "ReferenceDataLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.log_group_arn["reference_data"]]
  }
}

resource "aws_iam_policy" "reference_data_permissions" {
  name   = "${local.name_prefix}-reference-data-permissions"
  policy = data.aws_iam_policy_document.reference_data_permissions.json
}

resource "aws_iam_role_policy_attachment" "reference_data_permissions_attach" {
  role       = aws_iam_role.reference_data_exec.name
  policy_arn = aws_iam_policy.reference_data_permissions.arn
}
