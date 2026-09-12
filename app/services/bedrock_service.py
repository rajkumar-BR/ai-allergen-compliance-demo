"""
bedrock_service.py

Thin wrapper around Amazon Bedrock's Converse API for the two Bedrock-backed
features in the project brief:

  1. Allergen extraction from a free-text dish description (Step 1 of the
     "Two-Step AI Chain" - no knowledge base / RAG lookup is used, per
     project scope; the model is grounded purely with the PEAL category
     list passed in the prompt).
  2. Context-aware multilingual translation of dish name + description
     into Spanish, German, Japanese and Mandarin (Step 2).

If AWS credentials / Bedrock access are not available (e.g. running the
app locally without an AWS account, or the model hasn't been granted
access yet in this account/region), every function here degrades to a
clearly-labelled offline stub so the rest of the app - UI, DynamoDB,
S3, allergen rules engine - can still be exercised end to end.
"""
from __future__ import annotations
import json
import logging
import os
from typing import Dict, List

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from .allergen_rules import PEAL_CATEGORIES

logger = logging.getLogger(__name__)

AWS_REGION = os.environ.get("AWS_REGION", "ap-southeast-2")
BEDROCK_MODEL_ID = os.environ.get(
    "BEDROCK_MODEL_ID", "anthropic.claude-3-haiku-20240307-v1:0"
)
LOCAL_MODE = os.environ.get("LOCAL_MODE", "false").lower() == "true"

LANGUAGES = {
    "es": "Spanish",
    "de": "German",
    "ja": "Japanese",
    "zh": "Mandarin Chinese (Simplified)",
}

_client = None


def _get_client():
    global _client
    if _client is None:
        _client = boto3.client("bedrock-runtime", region_name=AWS_REGION)
    return _client


def _converse(system_prompt: str, user_prompt: str, max_tokens: int = 700) -> str:
    client = _get_client()
    response = client.converse(
        modelId=BEDROCK_MODEL_ID,
        system=[{"text": system_prompt}],
        messages=[{"role": "user", "content": [{"text": user_prompt}]}],
        inferenceConfig={"maxTokens": max_tokens, "temperature": 0},
    )
    return response["output"]["message"]["content"][0]["text"]


def _extract_json(raw: str) -> dict:
    """Bedrock models sometimes wrap JSON in prose or code fences - strip it."""
    raw = raw.strip()
    if "```" in raw:
        raw = raw.split("```")[1] if raw.count("```") >= 2 else raw
        raw = raw.replace("json", "", 1).strip() if raw.lower().startswith("json") else raw
    start = raw.find("{")
    end = raw.rfind("}")
    if start != -1 and end != -1:
        raw = raw[start:end + 1]
    return json.loads(raw)


def extract_allergens(dish_name: str, description: str) -> Dict:
    """Return {'categories': [...], 'reasoning': str} using the Bedrock LLM.

    Falls back to a local (non-AI) result if Bedrock is unreachable, so the
    caller can always merge this with the deterministic rules-engine pass.
    """
    if LOCAL_MODE:
        return _offline_extract_allergens(dish_name, description)

    system_prompt = (
        "You are a food-safety compliance assistant for New Zealand "
        "restaurants, checking dishes against the FSANZ Standard 1.2.3 "
        "mandatory declarable allergen list. Only choose categories from "
        f"this exact list: {PEAL_CATEGORIES}. "
        "Respond with ONLY a JSON object, no prose, no markdown fences, "
        'in the form {"categories": ["..."], "reasoning": "..."}. '
        "If uncertain whether an ingredient is present, err on the side "
        "of including the category (under-declaring an allergen is unsafe)."
    )
    user_prompt = f"Dish name: {dish_name}\nDescription: {description}"
    try:
        raw = _converse(system_prompt, user_prompt)
        parsed = _extract_json(raw)
        categories = [c for c in parsed.get("categories", []) if c in PEAL_CATEGORIES]
        return {"categories": categories, "reasoning": parsed.get("reasoning", ""), "source": "bedrock"}
    except (BotoCoreError, ClientError, json.JSONDecodeError, KeyError, IndexError) as exc:
        logger.warning("Bedrock allergen extraction failed, using offline fallback: %s", exc)
        result = _offline_extract_allergens(dish_name, description)
        result["error"] = str(exc)
        return result


def _offline_extract_allergens(dish_name: str, description: str) -> Dict:
    from .allergen_rules import scan_text_for_allergens
    categories = scan_text_for_allergens(f"{dish_name} {description}")
    return {"categories": categories, "reasoning": "offline keyword fallback (Bedrock unavailable)", "source": "offline"}


def translate_dish(dish_name: str, description: str) -> Dict[str, Dict[str, str]]:
    """Translate name+description into all configured LANGUAGES.

    Returns { 'es': {'name': ..., 'description': ...}, 'de': {...}, ... }
    """
    if LOCAL_MODE:
        return _offline_translate(dish_name, description)

    system_prompt = (
        "You are a professional culinary translator for restaurant menus "
        "shown to international tourists in New Zealand. Preserve the "
        "meaning of culinary terms (e.g. keep 'chowder', 'ribeye' style "
        "naming conventions native speakers would recognise; do not "
        "invent ingredients that were not mentioned). "
        "Respond with ONLY a JSON object, no prose, no markdown fences, "
        "mapping each language code to {\"name\": ..., \"description\": ...}. "
        f"Language codes and names: {LANGUAGES}"
    )
    user_prompt = f"Dish name: {dish_name}\nDescription: {description}"
    try:
        raw = _converse(system_prompt, user_prompt, max_tokens=900)
        parsed = _extract_json(raw)
        result = {}
        for code in LANGUAGES:
            entry = parsed.get(code, {})
            result[code] = {
                "name": entry.get("name", dish_name),
                "description": entry.get("description", description),
            }
        return result
    except (BotoCoreError, ClientError, json.JSONDecodeError, KeyError, IndexError) as exc:
        logger.warning("Bedrock translation failed, trying Amazon Translate fallback: %s", exc)
        return _translate_fallback(dish_name, description, str(exc))


def _translate_fallback(dish_name: str, description: str, bedrock_error: str) -> Dict:
    """Second-line fallback: Amazon Translate (plain MT, no culinary context
    preservation) - only used if the Bedrock call itself fails."""
    try:
        client = boto3.client("translate", region_name=AWS_REGION)
        result = {}
        for code in LANGUAGES:
            name = client.translate_text(
                Text=dish_name, SourceLanguageCode="en", TargetLanguageCode=code
            )["TranslatedText"]
            desc = client.translate_text(
                Text=description, SourceLanguageCode="en", TargetLanguageCode=code
            )["TranslatedText"]
            result[code] = {"name": name, "description": desc, "engine": "amazon_translate_fallback"}
        return result
    except (BotoCoreError, ClientError) as exc:
        logger.warning("Amazon Translate fallback also failed, using offline stub: %s", exc)
        stub = _offline_translate(dish_name, description)
        stub["_error"] = f"bedrock: {bedrock_error}; translate: {exc}"
        return stub


def _offline_translate(dish_name: str, description: str) -> Dict:
    return {
        code: {
            "name": f"[{lang} - offline] {dish_name}",
            "description": f"[{lang} translation unavailable offline] {description}",
        }
        for code, lang in LANGUAGES.items()
    }
