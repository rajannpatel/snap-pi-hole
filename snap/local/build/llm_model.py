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
DEFAULT_MODEL = os.environ.get("LLM_DEFAULT_MODEL") or "openai/gpt-4.1"

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


class LLMProvider:
    def __init__(self, name, api_key, base_url, default_model):
        self.name = name
        self.api_key = api_key
        self.base_url = base_url
        self.default_model = default_model
        self.models = [default_model]
        self.discovered = False
        self.cooldown_until = 0.0


def init_providers():
    providers = []
    
    # 1. Gemini
    gemini_key = os.environ.get("LLM_GEMINI_KEY") or os.environ.get("GEMINI_API_KEY")
    # 2. GitHub
    github_key = os.environ.get("LLM_GITHUB_KEY") or os.environ.get("GITHUB_TOKEN")
    
    # Check fallback/compatibility with LLM_API_KEY / LLM_API_BASE_URL
    llm_api_key = os.environ.get("LLM_API_KEY")
    llm_api_base_url = os.environ.get("LLM_API_BASE_URL")
    
    if llm_api_key:
        is_gemini_url = llm_api_base_url and "googleapis.com" in llm_api_base_url
        is_gemini_key = llm_api_key.startswith("AIza")
        if is_gemini_url or is_gemini_key:
            if not gemini_key:
                gemini_key = llm_api_key
        else:
            if not github_key:
                github_key = llm_api_key

    # Initialize Gemini provider if key is available
    if gemini_key:
        default_gemini_base = "https://generativelanguage.googleapis.com/v1beta/openai"
        if gemini_key == llm_api_key and llm_api_base_url:
            default_gemini_base = llm_api_base_url
        gemini_base = os.environ.get("LLM_GEMINI_BASE_URL") or default_gemini_base
        gemini_default_model = os.environ.get("LLM_GEMINI_DEFAULT_MODEL") or "gemini-1.5-flash"
        providers.append(LLMProvider("Gemini", gemini_key, gemini_base, gemini_default_model))
        
    # Initialize GitHub provider if key is available
    if github_key:
        default_github_base = "https://models.github.ai/inference"
        if github_key == llm_api_key and llm_api_base_url:
            default_github_base = llm_api_base_url
        github_base = os.environ.get("LLM_GITHUB_BASE_URL") or default_github_base
        github_default_model = os.environ.get("LLM_GITHUB_DEFAULT_MODEL") or "openai/gpt-4.1"
        providers.append(LLMProvider("GitHub", github_key, github_base, github_default_model))
        
    return providers


def select_candidate_models(api_key=None, base_url=None):
    """Return a list of available free-tier model IDs ordered by preference, or [DEFAULT_MODEL] on failure."""
    if not api_key:
        return [DEFAULT_MODEL]

    if base_url is None:
        base_url = os.environ.get("LLM_API_BASE_URL") or "https://models.github.ai/inference"
    is_gemini = "googleapis.com" in base_url
    
    if is_gemini:
        try:
            url = f"{base_url.rstrip('/')}/models"
            req = urllib.request.Request(
                url,
                headers={
                    "Accept": "application/json",
                    "Authorization": f"Bearer {api_key}"
                },
                method="GET"
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            
            models = data.get("data", []) if isinstance(data, dict) else []
            model_ids = [m.get("id") for m in models if isinstance(m, dict) and m.get("id")]
            gemini_candidates = [mid for mid in model_ids if "gemini" in mid.lower()]
            
            if gemini_candidates:
                def gemini_rank(model_id):
                    name = model_id.lower()
                    import re
                    version = 1.5
                    match = re.search(r"gemini-(\d+(?:\.\d+)?)", name)
                    if match:
                        try:
                            version = float(match.group(1))
                        except ValueError:
                            pass
                    # Prefer Flash/Lite/nano over Pro models to avoid extremely restrictive
                    # Pro rate limits (often 2 RPM or 0 quota on free accounts).
                    is_flash = "flash" in name or "lite" in name or "nano" in name
                    is_pro = "pro" in name
                    if is_flash:
                        model_class = 0
                    elif is_pro:
                        model_class = 2
                    else:
                        model_class = 1
                    return (model_class, -version, name)
                
                gemini_candidates.sort(key=gemini_rank)
                print(f"Discovered Gemini models in preference order: {gemini_candidates}", file=sys.stderr)
                return gemini_candidates
        except Exception as exc:
            print(f"Gemini model discovery failed ({exc}); falling back to default model {DEFAULT_MODEL}.", file=sys.stderr)
            return [DEFAULT_MODEL]

    try:
        catalog = fetch_catalog(api_key=api_key)
    except (urllib.error.URLError, ValueError, OSError) as exc:
        print(
            f"Model catalog lookup failed ({exc}); using default model {DEFAULT_MODEL}.",
            file=sys.stderr,
        )
        return [DEFAULT_MODEL]

    candidates = [m for m in catalog if _is_candidate(m)]
    if not candidates:
        print(
            f"No catalog model matched selection criteria; using default model {DEFAULT_MODEL}.",
            file=sys.stderr,
        )
        return [DEFAULT_MODEL]

    # Stable sorts applied least-significant first: id asc, version desc, tier asc.
    candidates.sort(key=lambda m: m.get("id", ""))
    candidates.sort(key=lambda m: _version_key(m.get("version")), reverse=True)
    candidates.sort(key=lambda m: FREE_TIER_RANK.get(m.get("rate_limit_tier"), 9))
    return [m.get("id") or DEFAULT_MODEL for m in candidates]


def select_best_model(api_key=None, base_url=None):
    """Return the best available free-tier model id, or DEFAULT_MODEL on failure."""
    candidates = select_candidate_models(api_key, base_url)
    return candidates[0] if candidates else DEFAULT_MODEL


