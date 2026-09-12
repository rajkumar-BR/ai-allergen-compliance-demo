"""
Shared admin-auth helper for every Lambda that guards a mutating route.

This is the serverless equivalent of the old Flask app's inline
LOCAL_FAKE_ADMIN_TOKEN check: a single shared admin credential (no per-user
identity, no Cognito) whose password lives in Secrets Manager rather than in
source. Every Lambda that needs to gate a write imports this module instead
of re-implementing the check, so the token format and secret lookup can only
drift in one place.

Not real multi-user auth - see the project README's "Known limitations" for
what a production version would need (Cognito JWTs, per-user identity).
"""
from __future__ import annotations

import os
from typing import Any, Dict, Optional

import boto3

# The single shared token issued by /auth/login on a correct password. There
# is no expiry/rotation - this mirrors the previous Flask behaviour exactly.
ADMIN_TOKEN = "local-fake-admin-token"

# Secrets Manager secret id holding the current admin password (terraform/secrets.tf).
# Lambda env vars are set by AWS before the runtime starts, so - unlike the old
# Beanstalk/gunicorn setup - there is no import-ordering hazard here: every
# handler module can read this constant at import time safely.
ADMIN_PASSWORD_SECRET_ID = os.environ.get("ADMIN_PASSWORD_SECRET_ID", "")

# Only used when no secret is configured (e.g. a local unit test importing
# this module directly) - never reachable in a real deployment.
_LOCAL_DEV_FALLBACK_PASSWORD = "admin"

_secrets_client = None


def _client():
    global _secrets_client
    if _secrets_client is None:
        _secrets_client = boto3.client(
            "secretsmanager", region_name=os.environ.get("AWS_REGION", "ap-southeast-2")
        )
    return _secrets_client


def get_admin_password() -> str:
    if not ADMIN_PASSWORD_SECRET_ID:
        return _LOCAL_DEV_FALLBACK_PASSWORD
    resp = _client().get_secret_value(SecretId=ADMIN_PASSWORD_SECRET_ID)
    return resp["SecretString"]


def set_admin_password(new_password: str) -> None:
    if not ADMIN_PASSWORD_SECRET_ID:
        raise RuntimeError("ADMIN_PASSWORD_SECRET_ID is not set - nowhere to persist the new password")
    _client().put_secret_value(SecretId=ADMIN_PASSWORD_SECRET_ID, SecretString=new_password)


def _get_header(headers: Optional[Dict[str, Any]], name: str) -> str:
    """API Gateway v2 lower-cases header names, but check both cases defensively."""
    headers = headers or {}
    return headers.get(name.lower()) or headers.get(name) or ""


def is_authorized(event: Dict[str, Any]) -> bool:
    """True when the request carries the current admin bearer token."""
    auth_header = _get_header(event.get("headers"), "authorization")
    return auth_header == f"Bearer {ADMIN_TOKEN}"
