"""
Shared API Gateway HTTP API (v2) response helpers, used by every Lambda
handler so the JSON envelope (and Decimal-safe serialization of DynamoDB
numbers) is identical everywhere instead of re-implemented per handler.
"""
from __future__ import annotations

import json
from decimal import Decimal
from typing import Any, Dict


def json_default(o: Any):
    """json.dumps default hook: DynamoDB numbers come back as Decimal."""
    if isinstance(o, Decimal):
        return int(o) if o == o.to_integral_value() else float(o)
    raise TypeError(f"Object of type {type(o).__name__} is not JSON serializable")


def response(status_code: int, body: Dict[str, Any], extra_headers: Dict[str, str] | None = None) -> Dict[str, Any]:
    """Build an API Gateway HTTP API v2 proxy response with a JSON body."""
    headers = {"Content-Type": "application/json"}
    if extra_headers:
        headers.update(extra_headers)
    return {
        "statusCode": status_code,
        "headers": headers,
        "body": json.dumps(body, default=json_default),
    }


def error(status_code: int, message: str, **extra: Any) -> Dict[str, Any]:
    """Standard error envelope: ``{"error": "<description>", ...extra}``."""
    body = {"error": message}
    body.update(extra)
    return response(status_code, body)


def parse_json_body(event: Dict[str, Any]) -> Dict[str, Any]:
    """Best-effort JSON body parse (mirrors Flask's request.get_json(silent/force=True)).

    Returns {} for a missing/empty/non-JSON/non-object body rather than raising -
    callers that require specific fields validate those themselves and return
    their own 400, matching the previous Flask routes' tolerant parsing.
    """
    import base64
    import binascii

    raw = event.get("body")
    if raw is None or raw == "":
        return {}
    if event.get("isBase64Encoded"):
        try:
            raw = base64.b64decode(raw).decode("utf-8")
        except (binascii.Error, ValueError, UnicodeDecodeError):
            return {}
    try:
        parsed = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return {}
    return parsed if isinstance(parsed, dict) else {}
