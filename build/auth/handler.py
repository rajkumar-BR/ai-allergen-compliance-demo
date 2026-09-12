"""
auth Lambda handler.

Serves the two admin-auth endpoints behind API Gateway HTTP API (v2):

    POST /auth/login            -> {username, password} -> {token}
    POST /auth/change-password  -> {current_password, new_password} (bearer token required)

This is the serverless equivalent of the old Flask app's inline login route.
There is a single shared admin account (no per-user identity, no Cognito -
see services/auth_service.py); the password lives in Secrets Manager
(terraform/secrets.tf) instead of source, and change-password rotates it via
PutSecretValue so a redeploy is never needed to change it.
"""
from __future__ import annotations

from typing import Any, Dict

from services import auth_service
from services.http_response import error, parse_json_body, response

ROUTE_LOGIN = "POST /auth/login"
ROUTE_CHANGE_PASSWORD = "POST /auth/change-password"


def _handle_login(event: Dict[str, Any]) -> Dict[str, Any]:
    body = parse_json_body(event)
    username = body.get("username")
    password = body.get("password")
    if username == "admin" and password == auth_service.get_admin_password():
        return response(200, {"token": auth_service.ADMIN_TOKEN})
    return error(401, "invalid credentials")


def _handle_change_password(event: Dict[str, Any]) -> Dict[str, Any]:
    if not auth_service.is_authorized(event):
        return error(401, "unauthorized - login as admin first")

    body = parse_json_body(event)
    current_password = body.get("current_password", "")
    new_password = body.get("new_password", "")

    if current_password != auth_service.get_admin_password():
        return error(401, "current password is incorrect")
    if not new_password or len(new_password) < 4:
        return error(400, "new password must be at least 4 characters")

    try:
        auth_service.set_admin_password(new_password)
    except Exception as exc:  # noqa: BLE001
        return error(500, "could not update password", detail=str(exc))
    return response(200, {"status": "password updated"})


def handler(event: Dict[str, Any], context: Any = None) -> Dict[str, Any]:
    route_key = (event or {}).get("routeKey")
    if route_key == ROUTE_LOGIN:
        return _handle_login(event)
    if route_key == ROUTE_CHANGE_PASSWORD:
        return _handle_change_password(event)
    return error(404, "route not found")
