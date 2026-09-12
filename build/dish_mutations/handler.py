"""
dish_mutations Lambda handler.

Serves every admin-protected dish-mutation route other than the single-field
PATCH correction (that stays in editMenu, build/edit_menu/handler.py):

    POST   /menus/{menuId}/items              -> add one dish manually, run the full pipeline
    DELETE /menus/{menuId}/items/{itemId}      -> delete one dish
    DELETE /menus/{menuId}                     -> delete every dish under a menu ("Clear dishes")
    POST   /menus/{menuId}/seed                -> load the 8 bundled sample dishes through the pipeline

All four require the shared admin bearer token (services.auth_service) - the
previous Flask app left three of these four unauthenticated (a documented gap
in the original README's "Known limitations"); this rewrite closes that gap
rather than carrying it forward, since every route here mutates shared data.
"""
from __future__ import annotations

import json
import logging
import os
from typing import Any, Dict

from services import auth_service, dynamo_service, pipeline_service
from services.http_response import error, parse_json_body, response

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

ROUTE_CREATE_ITEM = "POST /menus/{menuId}/items"
ROUTE_DELETE_ITEM = "DELETE /menus/{menuId}/items/{itemId}"
ROUTE_DELETE_MENU = "DELETE /menus/{menuId}"
ROUTE_SEED = "POST /menus/{menuId}/seed"

SAMPLE_DATA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sample_menu.json")


def _path_param(event: Dict[str, Any], name: str):
    return (event.get("pathParameters") or {}).get(name)


def _handle_create_item(event: Dict[str, Any]) -> Dict[str, Any]:
    menu_id = _path_param(event, "menuId")
    body = parse_json_body(event)
    name = (body.get("name") or "").strip()
    description = (body.get("description") or "").strip()
    if not name:
        return error(400, "name is required")
    item = pipeline_service.run_pipeline(menu_id, name, description, source="manual")
    return response(201, {"item": item})


def _handle_delete_item(event: Dict[str, Any]) -> Dict[str, Any]:
    menu_id = _path_param(event, "menuId")
    item_id = _path_param(event, "itemId")
    dynamo_service.delete_item(menu_id, item_id)
    return response(200, {"deleted": item_id})


def _handle_delete_menu(event: Dict[str, Any]) -> Dict[str, Any]:
    menu_id = _path_param(event, "menuId")
    deleted_count = dynamo_service.delete_menu(menu_id)
    return response(200, {"deleted_menu": menu_id, "deleted_count": deleted_count})


def _handle_seed(event: Dict[str, Any]) -> Dict[str, Any]:
    menu_id = _path_param(event, "menuId")
    with open(SAMPLE_DATA_PATH, "r", encoding="utf-8") as f:
        sample = json.load(f)

    created = []
    for dish in sample["items"]:
        item = pipeline_service.run_pipeline(menu_id, dish["name"], dish["description"], source="sample")
        created.append(item)
    return response(201, {"menu_id": menu_id, "items": created})


def handler(event: Dict[str, Any], context: Any = None) -> Dict[str, Any]:
    if not auth_service.is_authorized(event):
        return error(401, "unauthorized - login as admin first")

    route_key = (event or {}).get("routeKey")
    try:
        if route_key == ROUTE_CREATE_ITEM:
            return _handle_create_item(event)
        if route_key == ROUTE_DELETE_ITEM:
            return _handle_delete_item(event)
        if route_key == ROUTE_DELETE_MENU:
            return _handle_delete_menu(event)
        if route_key == ROUTE_SEED:
            return _handle_seed(event)
    except Exception as exc:  # noqa: BLE001
        logger.exception("dish_mutations route=%s failed", route_key)
        return error(500, "request failed", detail=str(exc))

    return error(404, "route not found")
