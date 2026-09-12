"""
allergen_api Lambda handler.

Serves the two standalone allergen-analysis endpoints (public, no admin auth -
matches the previous Flask behaviour, and docs/allergen-api.md's documented
external contract):

    POST /allergens/extract   {dish_name|name, description} -> extraction result
    POST /compliance/verify   {dish_name|name, description, allergens?} -> compliance verdict

These do not persist anything to DynamoDB - they are pure analysis calls, used
both by the docs/allergen-api.md external contract and (indirectly, via
services/pipeline_service.py) by the dish-creation Lambdas.
"""
from __future__ import annotations

import logging
import uuid
from typing import Any, Dict, Tuple

from services import allergen_service
from services.http_response import error, parse_json_body, response

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

ROUTE_EXTRACT = "POST /allergens/extract"
ROUTE_VERIFY = "POST /compliance/verify"


def _dish_from_json(body: Dict[str, Any]) -> Tuple[str, str]:
    name = (body.get("dish_name") or body.get("name") or "").strip()
    description = (body.get("description") or "").strip()
    return name, description


def _handle_extract(event: Dict[str, Any]) -> Dict[str, Any]:
    request_id = uuid.uuid4().hex[:12]
    body = parse_json_body(event)
    name, description = _dish_from_json(body)
    if not name:
        return error(400, "dish_name (or name) is required")
    try:
        result = allergen_service.extract(name, description)
        logger.info("allergens/extract request_id=%s dish=%r allergens=%d", request_id, name, len(result.allergens))
        return response(200, result.to_json())
    except Exception as exc:  # noqa: BLE001 - surface as a 500, never a fake result
        logger.error("allergens/extract request_id=%s failed: %s", request_id, exc)
        return error(500, "extraction failed", detail=str(exc))


def _handle_verify(event: Dict[str, Any]) -> Dict[str, Any]:
    request_id = uuid.uuid4().hex[:12]
    body = parse_json_body(event)
    name, description = _dish_from_json(body)
    if not name:
        return error(400, "dish_name (or name) is required")
    try:
        provided = body.get("allergens")
        result = allergen_service.verify(name, provided, description=description)
        logger.info("compliance/verify request_id=%s dish=%r status=%s", request_id, name, result.status)
        return response(200, result.to_json())
    except Exception as exc:  # noqa: BLE001
        logger.error("compliance/verify request_id=%s failed: %s", request_id, exc)
        return error(500, "verification failed", detail=str(exc))


def handler(event: Dict[str, Any], context: Any = None) -> Dict[str, Any]:
    route_key = (event or {}).get("routeKey")
    if route_key == ROUTE_EXTRACT:
        return _handle_extract(event)
    if route_key == ROUTE_VERIFY:
        return _handle_verify(event)
    return error(404, "route not found")
