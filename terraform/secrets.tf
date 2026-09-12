# ---------------------------------------------------------------------------
# Admin login password for the app's shared admin login (POST /auth/login,
# served by build/auth/handler.py). Never hardcoded in source - it lives in
# Secrets Manager, and the app's "Change Password" admin action rotates it
# via PutSecretValue so a redeploy is never needed to change it.
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "app_admin_password" {
  name        = "${local.name_prefix}-app-admin-password"
  description = "Password for the app's shared admin login (POST /auth/login)."
  tags        = local.common_tags
}

resource "aws_secretsmanager_secret_version" "app_admin_password" {
  secret_id     = aws_secretsmanager_secret.app_admin_password.id
  secret_string = var.app_admin_initial_password

  lifecycle {
    # The app's own change-password endpoint updates this value directly via
    # PutSecretValue; a later `terraform apply` must not stomp that back to
    # the initial value.
    ignore_changes = [secret_string]
  }
}
