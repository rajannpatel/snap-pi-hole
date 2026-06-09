#!/usr/bin/env python3
"""Runtime discovery of the best GitHub Models model available to the CI token.

The analysis model is selected from the live GitHub Models catalog at run time
rather than hardcoded, so the pipeline automatically adopts the most capable
free-tier model as the catalog evolves over time.

Selection is restricted to text-capable OpenAI models in a free rate-limit tier
("high"/"low"):

* OpenAI publisher, because the report pipeline depends on the OpenAI-style
  ``response_format: {"type": "json_object"}`` contract, which is reliably
  supported across OpenAI models on the endpoint.
* "high"/"low" tiers only, because "custom" tier models (e.g. the gpt-5 and
  o-series) require paid/BYOK access and are not callable with the free
  ``GITHUB_TOKEN`` used in CI, and "embeddings" models cannot do chat
  completions.

Among the candidates the most capable is taken first by tier (high over low,
i.e. flagship over mini/nano) and then by newest version date. If the catalog
cannot be reached or yields no candidate, selection falls back to
``DEFAULT_MODEL`` so discovery never breaks a run.
"""
import json
import os
import sys
import urllib.error
import urllib.request

# Fallback when catalog discovery is unavailable. gpt-4.1 is the most capable
# OpenAI model in the free GITHUB_TOKEN ("High") tier at the time of writing.
DEFAULT_MODEL = "openai/gpt-4.1"

CATALOG_URL = os.environ.get("LLM_CATALOG_URL") or "https://models.github.ai/catalog/models"

# Publishers whose chat models reliably support response_format=json_object.
ALLOWED_PUBLISHERS = ("OpenAI",)

# Rate-limit tiers callable with the free GITHUB_TOKEN, best first.
FREE_TIER_RANK = {"high": 0, "low": 1}


def _version_key(version):
    """Sort key for an ISO-like ``YYYY-MM-DD`` version; non-dates rank oldest."""
    parts = str(version or "").split("-")
    if len(parts) == 3 and all(p.isdigit() for p in parts):
        return tuple(int(p) for p in parts)
    return (0, 0, 0)


def _is_candidate(model):
    if not isinstance(model, dict):
        return False
    if model.get("publisher") not in ALLOWED_PUBLISHERS:
        return False
    if model.get("rate_limit_tier") not in FREE_TIER_RANK:
        return False
    inputs = model.get("supported_input_modalities") or []
    outputs = model.get("supported_output_modalities") or []
    return "text" in inputs and "text" in outputs


def fetch_catalog(api_key=None, timeout=20):
    headers = {"Accept": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(CATALOG_URL, headers=headers, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data if isinstance(data, list) else []


def select_best_model(api_key=None):
    """Return the best available free-tier model id, or DEFAULT_MODEL on failure."""
    try:
        catalog = fetch_catalog(api_key=api_key)
    except (urllib.error.URLError, ValueError, OSError) as exc:
        print(
            f"Model catalog lookup failed ({exc}); using default model {DEFAULT_MODEL}.",
            file=sys.stderr,
        )
        return DEFAULT_MODEL

    candidates = [m for m in catalog if _is_candidate(m)]
    if not candidates:
        print(
            f"No catalog model matched selection criteria; using default model {DEFAULT_MODEL}.",
            file=sys.stderr,
        )
        return DEFAULT_MODEL

    # Stable sorts applied least-significant first: id asc, version desc, tier asc.
    candidates.sort(key=lambda m: m.get("id", ""))
    candidates.sort(key=lambda m: _version_key(m.get("version")), reverse=True)
    candidates.sort(key=lambda m: FREE_TIER_RANK.get(m.get("rate_limit_tier"), 9))
    return candidates[0].get("id") or DEFAULT_MODEL
