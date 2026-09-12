"""
reference_data Lambda handler.

Serves the three static/near-static public GET routes:

    GET /health
    GET /allergen-categories
    GET /languages

No DynamoDB/S3 access needed - this function's execution role is
logs-only.
"""
from __future__ import annotations

import os
from typing import Any, Dict

from services import allergen_rules, bedrock_service
from services.http_response import error, response

ROUTE_HEALTH = "GET /health"
ROUTE_ALLERGEN_CATEGORIES = "GET /allergen-categories"
ROUTE_LANGUAGES = "GET /languages"


def handler(event: Dict[str, Any], context: Any = None) -> Dict[str, Any]:
    route_key = (event or {}).get("routeKey")

    if route_key == ROUTE_HEALTH:
        return response(200, {"status": "ok", "local_mode": os.environ.get("LOCAL_MODE", "false")})
    if route_key == ROUTE_ALLERGEN_CATEGORIES:
        return response(200, {"categories": allergen_rules.PEAL_CATEGORIES})
    if route_key == ROUTE_LANGUAGES:
        return response(200, {"languages": bedrock_service.LANGUAGES})

    return error(404, "route not found")
