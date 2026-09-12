"""
Shared two-step dish pipeline: (1) allergen analyze + compliance verify, then
(2) translate. Every Lambda that creates a dish (manual add, upload/OCR, seed
sample menu) calls ``run_pipeline`` so the three call sites can never drift
from each other - this is a straight extraction of what used to be
``application.py``'s ``_run_pipeline`` in the Flask monolith, unchanged in
behaviour.

Compliance verification combines three signals: Bedrock LLM extraction, the
deterministic NZ PEAL rules engine, and (when available) Bedrock RAG
regulatory context (``allergen_service.retrieve_context``). The RAG layer
degrades to the bundled docs/*.md search when AWS is unavailable.
"""
from __future__ import annotations

from typing import Any, Dict

from services import allergen_rules, allergen_service, bedrock_service, dynamo_service


def run_pipeline(menu_id: str, name: str, description: str, source: str, persist: bool = True) -> Dict[str, Any]:
    """Run the full analyze -> verify -> translate chain for one dish.

    persist=False lets a caller processing many dishes concurrently (the
    upload Lambda) analyze them in parallel without writing each one
    individually, then persist afterward.
    """
    llm_result = bedrock_service.extract_allergens(name, description)
    rule_categories = allergen_rules.scan_text_for_allergens(f"{name} {description}")

    dish_text = f"{name} {description}".strip()
    retrieval = allergen_service.retrieve_context(dish_text)
    compliance = allergen_service.verify_pipeline(
        name,
        description,
        llm_result.get("categories", []),
        rule_categories,
        retrieval,
    )
    confirmed = compliance["confirmed"]

    translations = bedrock_service.translate_dish(name, description)

    item = {
        "menu_id": menu_id,
        "name": name,
        "description": description,
        "source": source,
        "status": "ai_verified",
        "allergens": {
            "confirmed": confirmed,
            "display_tags": allergen_rules.to_display_tags(confirmed),
            "llm_reasoning": llm_result.get("reasoning", ""),
            "llm_source": llm_result.get("source", "bedrock"),
            "disagreements": compliance["disagreements"],
            "rag_citations": compliance["citations"],
            "compliance": {
                "engine": compliance["engine"],
                "rag_categories": compliance["rag_categories"],
                "reasoning": compliance.get("reasoning", ""),
            },
        },
        "diet_tags": allergen_rules.derive_diet_tags(confirmed, f"{name} {description}"),
        "translations": translations,
    }
    return dynamo_service.put_item(item) if persist else item
