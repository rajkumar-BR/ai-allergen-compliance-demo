# API Gateway HTTP API (v2) fronting every menu Lambda function.
#
# Auth model: there is a single shared admin credential (no per-user Cognito
# identity - dropped in this rebuild since the app never actually consumed
# it). Every mutating route enforces a bearer-token check *inside* its own
# Lambda handler (services/auth_service.is_authorized), not at the gateway -
# so there is no JWT authorizer here, unlike the earlier Beanstalk-adjacent
# design. All routes use AWS_PROXY integrations (payload format 2.0).
#
# CORS: the frontend is hosted on Amplify (a different origin from this API's
# execute-api domain), so the HTTP API's native CORS support is enabled with
# a permissive origin list - acceptable for a public demo with no cookie-based
# auth (the admin token travels in an Authorization header, never a cookie).

resource "aws_apigatewayv2_api" "menu_api" {
  name          = "${local.name_prefix}-menu-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "PATCH", "DELETE", "OPTIONS"]
    allow_headers = ["content-type", "authorization"]
    max_age       = 300
  }

  tags = local.common_tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.menu_api.id
  name        = "$default"
  auto_deploy = true

  tags = local.common_tags
}

# --- Integrations (AWS_PROXY, payload format 2.0) ---------------------------

locals {
  integration_targets = {
    read_menu      = aws_lambda_function.read_menu
    edit_menu      = aws_lambda_function.edit_menu
    auth           = aws_lambda_function.auth
    dish_mutations = aws_lambda_function.dish_mutations
    upload_menu    = aws_lambda_function.upload_menu
    allergen_api   = aws_lambda_function.allergen_api
    reference_data = aws_lambda_function.reference_data
  }
}

resource "aws_apigatewayv2_integration" "this" {
  for_each = local.integration_targets

  api_id                 = aws_apigatewayv2_api.menu_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = each.value.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_lambda_permission" "apigw" {
  for_each = local.integration_targets

  statement_id  = "AllowInvokeFromMenuApi"
  action        = "lambda:InvokeFunction"
  function_name = each.value.function_name
  principal     = "apigateway.amazonaws.com"
  # Wildcard covers every method+route under this API, so each function needs
  # only this one permission statement even when it serves multiple routes.
  source_arn = "${aws_apigatewayv2_api.menu_api.execution_arn}/*/*"
}

# --- Routes ------------------------------------------------------------------

locals {
  routes = {
    # read_menu (public)
    get_menu_by_restaurant = { key = "GET /menus/{restaurantId}", target = "read_menu" }
    get_upload_status      = { key = "GET /menus/{uploadId}/status", target = "read_menu" }
    list_restaurants       = { key = "GET /restaurants", target = "read_menu" }

    # edit_menu (admin bearer token, checked inside the handler)
    patch_menu_item = { key = "PATCH /menus/{menuId}/items/{itemId}", target = "edit_menu" }

    # auth (public login; change-password checked inside the handler)
    auth_login           = { key = "POST /auth/login", target = "auth" }
    auth_change_password = { key = "POST /auth/change-password", target = "auth" }

    # dish_mutations (admin bearer token, checked inside the handler)
    create_item = { key = "POST /menus/{menuId}/items", target = "dish_mutations" }
    delete_item  = { key = "DELETE /menus/{menuId}/items/{itemId}", target = "dish_mutations" }
    delete_menu  = { key = "DELETE /menus/{menuId}", target = "dish_mutations" }
    seed_menu    = { key = "POST /menus/{menuId}/seed", target = "dish_mutations" }

    # upload_menu (admin bearer token, checked inside the handler)
    upload_menu = { key = "POST /menus/{menuId}/upload", target = "upload_menu" }

    # allergen_api (public analysis-only endpoints)
    allergens_extract = { key = "POST /allergens/extract", target = "allergen_api" }
    compliance_verify = { key = "POST /compliance/verify", target = "allergen_api" }

    # reference_data (public)
    health              = { key = "GET /health", target = "reference_data" }
    allergen_categories = { key = "GET /allergen-categories", target = "reference_data" }
    languages           = { key = "GET /languages", target = "reference_data" }
  }
}

resource "aws_apigatewayv2_route" "this" {
  for_each = local.routes

  api_id    = aws_apigatewayv2_api.menu_api.id
  route_key = each.value.key
  target    = "integrations/${aws_apigatewayv2_integration.this[each.value.target].id}"
}

# --- Output ------------------------------------------------------------------

output "menu_api_invoke_url" {
  description = "Base invoke URL for the menu HTTP API (every Lambda route)."
  value       = aws_apigatewayv2_stage.default.invoke_url
}
