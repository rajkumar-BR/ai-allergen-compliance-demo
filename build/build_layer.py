#!/usr/bin/env python3
"""Package the shared Lambda Layer used by every menu Lambda function.

This script copies every Python module from ``app/services/*.py`` into
``build/layer/python/services/`` **byte-for-byte, with no edits**. The copy is a
pure passthrough (``shutil.copy2``) so the "unmodified module" guarantee holds:
every Lambda function imports the exact same, unaltered service modules via
``from services import ...`` and therefore cannot drift.

It also copies the small regulatory ``docs/*.md`` files into
``build/layer/docs/`` (sibling to ``python/``), since
``allergen_service.KB_DOCS_DIR`` resolves to ``<its own dir>/../../docs`` -
inside the layer that is ``python/services/../../docs`` = ``docs/`` at the
layer root. Without this, the Bedrock-Knowledge-Base-unavailable RAG fallback
(local keyword search over docs/) would silently find zero sections in every
deployed Lambda. Only ``.md`` files are needed (the loader only reads those);
the large regulatory PDFs are source material for the optional Bedrock KB
ingestion (bedrock_kb.tf), not for this runtime fallback.

Layer layout produced (Lambda puts ``python/`` on ``sys.path`` and extracts
the whole zip to ``/opt``):

    build/layer/python/services/
        __init__.py
        allergen_rules.py
        allergen_service.py
        auth_service.py
        bedrock_service.py
        dynamo_service.py
        s3_service.py
        textract_service.py
    build/layer/docs/
        allergen-api.md
        knowledge-base-setup.md
        knowledge-base-usage.md
        nz_peal_allergens.md

Run from anywhere; paths are resolved relative to the repository root:

    python build/build_layer.py
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

# Repository root = parent of this script's directory (build/ -> repo root).
REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIR = REPO_ROOT / "app" / "services"
LAYER_SERVICES_DIR = REPO_ROOT / "build" / "layer" / "python" / "services"
DOCS_SOURCE_DIR = REPO_ROOT / "docs"
LAYER_DOCS_DIR = REPO_ROOT / "build" / "layer" / "docs"


def build_layer() -> list[Path]:
    """Copy every ``*.py`` module from app/services into the layer, verbatim.

    Returns the list of destination paths that were written.
    """
    if not SOURCE_DIR.is_dir():
        raise SystemExit(f"Source services directory not found: {SOURCE_DIR}")

    LAYER_SERVICES_DIR.mkdir(parents=True, exist_ok=True)

    copied: list[Path] = []
    for source in sorted(SOURCE_DIR.glob("*.py")):
        destination = LAYER_SERVICES_DIR / source.name
        # copy2 performs a byte-for-byte copy (and preserves metadata) with no
        # transformation whatsoever -- this is the unmodified-module guarantee.
        shutil.copy2(source, destination)
        copied.append(destination)

    return copied


def copy_docs() -> list[Path]:
    """Copy the small regulatory ``docs/*.md`` files into the layer's docs/."""
    if not DOCS_SOURCE_DIR.is_dir():
        return []

    LAYER_DOCS_DIR.mkdir(parents=True, exist_ok=True)

    copied: list[Path] = []
    for source in sorted(DOCS_SOURCE_DIR.glob("*.md")):
        destination = LAYER_DOCS_DIR / source.name
        shutil.copy2(source, destination)
        copied.append(destination)

    return copied


def main() -> int:
    copied = build_layer()
    if not copied:
        print(f"No .py modules found in {SOURCE_DIR}", file=sys.stderr)
        return 1

    print(f"Packaged {len(copied)} module(s) into {LAYER_SERVICES_DIR}:")
    for path in copied:
        print(f"  - {path.name}")

    docs_copied = copy_docs()
    print(f"Packaged {len(docs_copied)} doc(s) into {LAYER_DOCS_DIR}:")
    for path in docs_copied:
        print(f"  - {path.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
