# Every menu Lambda function and the shared services layer.
#
# The layer holds byte-for-byte copies of app/services/*.py (see
# build/build_layer.py) plus the small docs/*.md regulatory files (for the
# RAG-unavailable local fallback), so every function imports the exact same
# unmodified service modules via `from services import ...`. Each function
# package contains only its own handler.py (and, for dish_mutations, the
# bundled sample_menu.json); tests/caches are excluded from the deployment
# zips.
#
# Every function that touches DynamoDB gets BOTH env var names some piece of
# the codebase reads (MENU_TABLE_NAME - read_menu/edit_menu's own handlers;
# DYNAMODB_TABLE - services/dynamo_service.py, used by dish_mutations/
# upload_menu) pointed at the same table, so it never matters which
# convention a given module happens to use.
#
# Everything (DynamoDB, S3, the functions themselves, and Bedrock) lives in
# one region (var.aws_region) this time - the old Beanstalk build split
# DynamoDB/S3 into us-east-1 while Bedrock stayed in ap-southeast-2; this
# serverless rebuild has no reason to keep that split.

# --- Shared services layer -------------------------------------------------

data "archive_file" "layer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../build/layer"
  output_path = "${path.module}/build/layer.zip"
}

resource "aws_lambda_layer_version" "services" {
  layer_name          = "${local.name_prefix}-services"
  filename            = data.archive_file.layer_zip.output_path
  source_code_hash    = data.archive_file.layer_zip.output_base64sha256
  compatible_runtimes = ["python3.12"]
}

# --- Function packages (handler.py [+ small bundled data] only) ------------

data "archive_file" "read_menu_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../build/read_menu"
  output_path = "${path.module}/build/read_menu.zip"
  excludes    = ["test_*.py", ".pytest_cache", ".hypothesis", "__pycache__"]
}

data "archive_file" "edit_menu_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../build/edit_menu"
  output_path = "${path.module}/build/edit_menu.zip"
  excludes    = ["test_*.py", ".pytest_cache", ".hypothesis", "__pycache__"]
}

data "archive_file" "auth_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../build/auth"
  output_path = "${path.module}/build/auth.zip"
  excludes    = ["test_*.py", ".pytest_cache", ".hypothesis", "__pycache__"]
}

data "archive_file" "dish_mutations_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../build/dish_mutations"
  output_path = "${path.module}/build/dish_mutations.zip"
  excludes    = ["test_*.py", ".pytest_cache", ".hypothesis", "__pycache__"]
}

data "archive_file" "upload_menu_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../build/upload_menu"
  output_path = "${path.module}/build/upload_menu.zip"
  excludes    = ["test_*.py", ".pytest_cache", ".hypothesis", "__pycache__"]
}

data "archive_file" "allergen_api_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../build/allergen_api"
  output_path = "${path.module}/build/allergen_api.zip"
  excludes    = ["test_*.py", ".pytest_cache", ".hypothesis", "__pycache__"]
}

data "archive_file" "reference_data_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../build/reference_data"
  output_path = "${path.module}/build/reference_data.zip"
  excludes    = ["test_*.py", ".pytest_cache", ".hypothesis", "__pycache__"]
}

# --- Lambda functions --------------------------------------------------------

resource "aws_lambda_function" "read_menu" {
  function_name    = local.lambda_function_names["read_menu"]
  role             = aws_iam_role.read_menu_exec.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.read_menu_zip.output_path
  source_code_hash = data.archive_file.read_menu_zip.output_base64sha256
  layers           = [aws_lambda_layer_version.services.arn]
  timeout          = 10

  environment {
    variables = {
      # read_menu's own routes (restaurants scan, upload-status) read
      # MENU_TABLE_NAME directly; its dish-listing route goes through
      # services/dynamo_service.py, which reads DYNAMODB_TABLE instead - both
      # must point at the same table or dish-listing silently queries the
      # wrong (nonexistent) table name and fails closed with AccessDenied.
      MENU_TABLE_NAME = aws_dynamodb_table.menu_items.name
      DYNAMODB_TABLE  = aws_dynamodb_table.menu_items.name
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_function" "edit_menu" {
  function_name    = local.lambda_function_names["edit_menu"]
  role             = aws_iam_role.edit_menu_exec.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.edit_menu_zip.output_path
  source_code_hash = data.archive_file.edit_menu_zip.output_base64sha256
  layers           = [aws_lambda_layer_version.services.arn]
  timeout          = 10

  environment {
    variables = {
      MENU_TABLE_NAME = aws_dynamodb_table.menu_items.name
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_function" "auth" {
  function_name    = local.lambda_function_names["auth"]
  role             = aws_iam_role.auth_exec.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.auth_zip.output_path
  source_code_hash = data.archive_file.auth_zip.output_base64sha256
  layers           = [aws_lambda_layer_version.services.arn]
  timeout          = 10

  environment {
    variables = {
      ADMIN_PASSWORD_SECRET_ID = aws_secretsmanager_secret.app_admin_password.id
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_function" "dish_mutations" {
  function_name    = local.lambda_function_names["dish_mutations"]
  role             = aws_iam_role.dish_mutations_exec.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.dish_mutations_zip.output_path
  source_code_hash = data.archive_file.dish_mutations_zip.output_base64sha256
  layers           = [aws_lambda_layer_version.services.arn]
  # Seeding 8 sample dishes (or a manual add) runs Bedrock extraction +
  # translation per dish synchronously - comfortably under a minute, but
  # given a generous margin over API Gateway's own 30s integration timeout
  # is impossible (HTTP APIs cap integration timeout at 30s), this is set to
  # the max useful value; a slow Bedrock call still fails as a clean gateway
  # timeout rather than a Lambda-side one.
  timeout     = 29
  memory_size = 512

  environment {
    variables = {
      DYNAMODB_TABLE   = aws_dynamodb_table.menu_items.name
      BEDROCK_MODEL_ID = var.bedrock_model_id
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_function" "upload_menu" {
  function_name    = local.lambda_function_names["upload_menu"]
  role             = aws_iam_role.upload_menu_exec.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.upload_menu_zip.output_path
  source_code_hash = data.archive_file.upload_menu_zip.output_base64sha256
  layers           = [aws_lambda_layer_version.services.arn]
  timeout          = 29 # see dish_mutations' comment on the API Gateway 30s ceiling
  memory_size      = 512

  environment {
    variables = {
      DYNAMODB_TABLE   = aws_dynamodb_table.menu_items.name
      S3_BUCKET        = aws_s3_bucket.menu_uploads.bucket
      BEDROCK_MODEL_ID = var.bedrock_model_id
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_function" "allergen_api" {
  function_name    = local.lambda_function_names["allergen_api"]
  role             = aws_iam_role.allergen_api_exec.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.allergen_api_zip.output_path
  source_code_hash = data.archive_file.allergen_api_zip.output_base64sha256
  layers           = [aws_lambda_layer_version.services.arn]
  timeout          = 20

  environment {
    variables = {
      BEDROCK_MODEL_ID = var.bedrock_model_id
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_function" "reference_data" {
  function_name    = local.lambda_function_names["reference_data"]
  role             = aws_iam_role.reference_data_exec.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.reference_data_zip.output_path
  source_code_hash = data.archive_file.reference_data_zip.output_base64sha256
  layers           = [aws_lambda_layer_version.services.arn]
  timeout          = 10

  tags = local.common_tags
}

# --- Outputs ---------------------------------------------------------------

output "read_menu_function_name" {
  value = aws_lambda_function.read_menu.function_name
}

output "edit_menu_function_name" {
  value = aws_lambda_function.edit_menu.function_name
}

output "auth_function_name" {
  value = aws_lambda_function.auth.function_name
}

output "dish_mutations_function_name" {
  value = aws_lambda_function.dish_mutations.function_name
}

output "upload_menu_function_name" {
  value = aws_lambda_function.upload_menu.function_name
}

output "allergen_api_function_name" {
  value = aws_lambda_function.allergen_api.function_name
}

output "reference_data_function_name" {
  value = aws_lambda_function.reference_data.function_name
}
