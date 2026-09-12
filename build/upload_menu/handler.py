"""
upload_menu Lambda handler.

Serves the file-upload route (admin-protected):

    POST /menus/{menuId}/upload   (multipart/form-data, field name "file")

API Gateway HTTP API v2 delivers a multipart body as a base64-encoded string
(isBase64Encoded=true) rather than Flask's parsed request.files, so this
handler decodes it and pulls the one "file" part out with a small
multipart/form-data parser built on Python's email package (a standard,
well-tested technique: prepend a synthetic Content-Type header to the raw
body bytes and let email.parser walk the MIME structure - multipart/form-data
is a MIME format, so this "just works" without a bespoke parser).

Note on size: API Gateway HTTP APIs cap request payloads at 10 MB, but a
synchronous Lambda invocation payload (API Gateway's proxied request) is
capped at 6 MB - and a base64-encoded file is ~33% larger than the original.
MAX_UPLOAD_BYTES is therefore set well under that ceiling. A production
version would have the browser upload straight to S3 via a presigned URL and
process asynchronously instead of proxying the whole file through API
Gateway + Lambda; that is out of scope for this pass (see README).
"""
from __future__ import annotations

import base64
import logging
from concurrent.futures import ThreadPoolExecutor
from email import message_from_bytes
from email.message import Message
from typing import Any, Dict, Optional, Tuple

from services import auth_service, dynamo_service, menu_parser, pipeline_service, s3_service, textract_service
from services.http_response import error, response

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

ROUTE_UPLOAD = "POST /menus/{menuId}/upload"

# Raw (pre-base64) upload size cap - see module docstring for why this is
# smaller than the old Flask app's 10 MB limit.
MAX_UPLOAD_BYTES = 4 * 1024 * 1024  # 4MB


def _path_param(event: Dict[str, Any], name: str):
    return (event.get("pathParameters") or {}).get(name)


def _content_type(event: Dict[str, Any]) -> str:
    headers = event.get("headers") or {}
    return headers.get("content-type") or headers.get("Content-Type") or ""


def _extract_file_part(event: Dict[str, Any]) -> Optional[Tuple[bytes, str, str]]:
    """Return (file_bytes, filename, content_type) for the "file" form field, or None."""
    content_type = _content_type(event)
    if "multipart/form-data" not in content_type:
        return None

    raw_body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        body_bytes = base64.b64decode(raw_body)
    else:
        body_bytes = raw_body.encode("utf-8")

    # Synthesize a minimal MIME message so email.parser can walk the
    # multipart structure for us instead of hand-rolling a boundary parser.
    mime_bytes = f"Content-Type: {content_type}\r\nMIME-Version: 1.0\r\n\r\n".encode("utf-8") + body_bytes
    message: Message = message_from_bytes(mime_bytes)

    if not message.is_multipart():
        return None

    for part in message.walk():
        content_disposition = part.get("Content-Disposition", "")
        if 'name="file"' not in content_disposition:
            continue
        filename = part.get_filename() or "upload"
        part_content_type = part.get_content_type() or "application/octet-stream"
        payload = part.get_payload(decode=True)
        if payload is None:
            continue
        return payload, filename, part_content_type

    return None


def handler(event: Dict[str, Any], context: Any = None) -> Dict[str, Any]:
    if not auth_service.is_authorized(event):
        return error(401, "unauthorized - login as admin first")

    route_key = (event or {}).get("routeKey")
    if route_key != ROUTE_UPLOAD:
        return error(404, "route not found")

    menu_id = _path_param(event, "menuId")

    try:
        parsed = _extract_file_part(event)
    except Exception as exc:  # noqa: BLE001
        logger.exception("upload_menu: could not parse multipart body")
        return error(400, "could not parse uploaded file", detail=str(exc))

    if parsed is None:
        return error(400, "multipart file field 'file' is required")

    file_bytes, filename, content_type = parsed
    if len(file_bytes) > MAX_UPLOAD_BYTES:
        return error(413, f"file exceeds the {MAX_UPLOAD_BYTES // (1024 * 1024)}MB upload limit")

    try:
        stored_path = s3_service.upload_raw_file(file_bytes, filename, content_type)
        lines = textract_service.extract_text_from_bytes(file_bytes, content_type)
        dishes = menu_parser.parse_ocr_lines(lines)

        with ThreadPoolExecutor() as executor:
            analyzed = list(executor.map(
                lambda d: pipeline_service.run_pipeline(menu_id, d["name"], d["description"], source="upload", persist=False),
                [d for d in dishes if d["name"]],
            ))

        created = [dynamo_service.put_item(item) for item in analyzed]
    except Exception as exc:  # noqa: BLE001
        logger.exception("upload_menu: pipeline failed for menu_id=%s", menu_id)
        return error(500, "upload processing failed", detail=str(exc))

    return response(201, {"stored_path": stored_path, "ocr_lines": lines, "items": created})
