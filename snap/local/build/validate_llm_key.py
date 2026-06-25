#!/usr/bin/env python3
"""Validate that LLM_API_KEY is set and accepted by the OpenAI/GitHub Models API.

Exits with status 0 on success, 1 on failure.
Emits GitHub Actions workflow commands so failures surface in the CI UI.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from llm_model import select_best_model, init_providers


def validate_provider(provider, has_alternatives=False):
    model = select_best_model(provider.api_key, provider.base_url)
    url = f"{provider.base_url.rstrip('/')}/chat/completions"
    body = {
        "model": model,
        "messages": [{"role": "user", "content": "Reply with exactly the word: ok"}],
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {provider.api_key}",
        },
        method="POST",
    )

    max_attempts = max(1, int(os.environ.get("LLM_MAX_ATTEMPTS") or "3"))
    retry_base_delay = max(0.0, float(os.environ.get("LLM_RETRY_BASE_DELAY_SECONDS") or "1.0"))

    for attempt in range(1, max_attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            text = (
                data.get("choices", [{}])[0]
                .get("message", {})
                .get("content", "")
            )
            print(f"{provider.name} LLM API key is valid. Model responded: {text.strip()!r}")
            return "SUCCESS", None
        except urllib.error.HTTPError as exc:
            body_text = ""
            try:
                body_text = exc.read().decode("utf-8", errors="replace").strip()
            except Exception:
                pass
            print(
                f"{provider.name} key validation HTTP error (attempt {attempt}/{max_attempts}): status {exc.code}. "
                f"Response body: {body_text or '<empty>'}",
                file=sys.stderr,
            )
            
            if exc.code == 429:
                if has_alternatives:
                    return "RATE_LIMIT", f"HTTP {exc.code}: {body_text}"
                
                if attempt < max_attempts:
                    sleep_delay = None
                    resp_headers = exc.headers or {}
                    retry_after = resp_headers.get("Retry-After")
                    if retry_after:
                        try:
                            sleep_delay = max(2.0, float(retry_after) + 0.5)
                            print(f"Rate limit detected. Sleeping for {sleep_delay:.2f}s via Retry-After header.", file=sys.stderr)
                        except ValueError:
                            pass
                    if sleep_delay is None:
                        reset_time = resp_headers.get("x-ratelimit-reset") or resp_headers.get("X-RateLimit-Reset")
                        if reset_time:
                            try:
                                sleep_delay = max(2.0, float(reset_time) - time.time() + 1.0)
                                print(f"Rate limit detected. Sleeping for {sleep_delay:.2f}s via x-ratelimit-reset header.", file=sys.stderr)
                            except ValueError:
                                pass
                    if sleep_delay is None and body_text:
                        import re
                        match = re.search(r"(?:retry in|try again in|retry after) (\d+\.?\d*)(?:\s*s|\s*second)", body_text, re.IGNORECASE)
                        if match:
                            try:
                                sleep_delay = max(2.0, float(match.group(1)) + 0.5)
                                print(f"Rate limit detected. Sleeping for {sleep_delay:.2f}s via response body.", file=sys.stderr)
                            except ValueError:
                                pass
                    if sleep_delay is None:
                        cap = 30.0
                        sleep_delay = max(2.0, min(retry_base_delay * (2 ** (attempt - 1)), cap))
                    time.sleep(sleep_delay)
                    continue
                return "RATE_LIMIT", f"HTTP {exc.code}: {body_text}"
                
            if exc.code in {500, 502, 503, 504} and attempt < max_attempts:
                sleep_delay = min(retry_base_delay * (2 ** (attempt - 1)), 8.0)
                time.sleep(sleep_delay)
                continue
            if exc.code in {500, 502, 503, 504}:
                return "TEMP_FAILURE", f"HTTP {exc.code}: {body_text}"
                
            return "PERM_FAILURE", f"HTTP {exc.code}: {body_text}"
            
        except (urllib.error.URLError, TimeoutError) as exc:
            print(
                f"{provider.name} key validation network error (attempt {attempt}/{max_attempts}): {exc}",
                file=sys.stderr,
            )
            if attempt < max_attempts:
                time.sleep(min(retry_base_delay * (2 ** (attempt - 1)), 8.0))
                continue
            return "TEMP_FAILURE", str(exc)
        except Exception as exc:
            print(
                f"{provider.name} key validation unexpected error: {type(exc).__name__}: {exc}",
                file=sys.stderr,
            )
            return "PERM_FAILURE", str(exc)


def main():
    providers = init_providers()
    if not providers:
        print(
            "::notice title=LLM validation::"
            "LLM_API_KEY is unavailable (expected for fork PRs). Skipping live key check."
        )
        return 0

    results = {}
    for i, provider in enumerate(providers):
        is_last = (i == len(providers) - 1)
        status, err = validate_provider(provider, has_alternatives=not is_last)
        results[provider.name] = (status, err)
        if status == "SUCCESS":
            return 0
            
    statuses = [status for status, _ in results.values()]
    if any(s in {"TEMP_FAILURE", "RATE_LIMIT"} for s in statuses):
        reasons = ", ".join(f"{name}: {err}" for name, (status, err) in results.items())
        print(
            f"::warning title=LLM key validation::All LLM APIs are temporarily unavailable or rate-limited ({reasons}). "
            f"Proceeding with build using cached justifications.",
            file=sys.stderr,
        )
        return 0

    reasons = ", ".join(f"{name}: {err}" for name, (status, err) in results.items())
    print(
        f"::error title=LLM key validation::All LLM validations failed permanently ({reasons}).",
        file=sys.stderr,
    )
    return 1



if __name__ == "__main__":
    sys.exit(main())
