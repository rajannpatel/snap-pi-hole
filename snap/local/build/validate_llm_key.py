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


def main():
    api_key = os.environ.get("LLM_API_KEY") or os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print(
            "::notice title=LLM validation::"
            "LLM_API_KEY is unavailable (expected for fork PRs). Skipping live key check."
        )
        return 0

    model = os.environ.get("LLM_MODEL") or os.environ.get("GEMINI_MODEL") or "gpt-4o"
    base_url = (
        os.environ.get("LLM_API_BASE_URL")
        or os.environ.get("GEMINI_API_BASE_URL")
        or "https://models.github.ai/inference"
    ).rstrip("/")

    url = f"{base_url}/chat/completions"
    body = {
        "model": model,
        "messages": [{"role": "user", "content": "Reply with exactly the word: ok"}],
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )

    max_attempts = max(1, int(os.environ.get("LLM_MAX_ATTEMPTS") or os.environ.get("GEMINI_MAX_ATTEMPTS") or "3"))
    retry_base_delay = max(0.0, float(os.environ.get("LLM_RETRY_BASE_DELAY_SECONDS") or os.environ.get("GEMINI_RETRY_BASE_DELAY_SECONDS") or "1.0"))

    for attempt in range(1, max_attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            text = (
                data.get("choices", [{}])[0]
                .get("message", {})
                .get("content", "")
            )
            print(f"LLM API key is valid. Model responded: {text.strip()!r}")
            return 0
        except urllib.error.HTTPError as exc:
            body_text = ""
            try:
                body_text = exc.read().decode("utf-8", errors="replace").strip()
            except Exception:
                pass
            print(
                f"LLM key validation HTTP error (attempt {attempt}/{max_attempts}): status {exc.code}. "
                f"Response body: {body_text or '<empty>'}",
                file=sys.stderr,
            )
            if exc.code in {429, 500, 502, 503, 504} and attempt < max_attempts:
                sleep_delay = None
                if exc.code == 429:
                    retry_after = exc.headers.get("Retry-After")
                    if retry_after:
                        try:
                            sleep_delay = float(retry_after) + 0.5
                            print(
                                f"Rate limit detected via Retry-After header. Sleeping for {sleep_delay:.2f}s.",
                                file=sys.stderr,
                            )
                        except ValueError:
                            pass
                    if sleep_delay is None:
                        reset_time = exc.headers.get("x-ratelimit-reset") or exc.headers.get("X-RateLimit-Reset")
                        if reset_time:
                            try:
                                sleep_delay = max(0.5, float(reset_time) - time.time() + 1.0)
                                print(
                                    f"Rate limit detected via x-ratelimit-reset header. Sleeping for {sleep_delay:.2f}s.",
                                    file=sys.stderr,
                                )
                            except ValueError:
                                pass
                    if sleep_delay is None and body_text:
                        import re
                        match = re.search(r"(?:retry in|try again in|retry after) (\d+\.?\d*)(?:\s*s|\s*second)", body_text, re.IGNORECASE)
                        if match:
                            try:
                                sleep_delay = float(match.group(1)) + 0.5
                                print(
                                    f"Rate limit detected via response body. Sleeping for {sleep_delay:.2f}s as requested by API.",
                                    file=sys.stderr,
                                )
                            except ValueError:
                                pass
                if sleep_delay is None:
                    cap = 30.0 if exc.code == 429 else 8.0
                    sleep_delay = min(retry_base_delay * (2 ** (attempt - 1)), cap)
                time.sleep(sleep_delay)
                continue
            if exc.code in {429, 500, 502, 503, 504}:
                print(
                    f"::warning title=LLM key validation::API is temporarily unavailable (HTTP {exc.code}). "
                    f"Proceeding with build using cached justifications.",
                    file=sys.stderr,
                )
                return 0
            print(
                f"::error title=LLM key validation::HTTP {exc.code} from LLM API. {body_text}",
                file=sys.stderr,
            )
            return 1
        except (urllib.error.URLError, TimeoutError) as exc:
            print(
                f"LLM key validation network error (attempt {attempt}/{max_attempts}): {exc}",
                file=sys.stderr,
            )
            if attempt < max_attempts:
                time.sleep(min(retry_base_delay * (2 ** (attempt - 1)), 8.0))
                continue
            print(
                f"::warning title=LLM key validation::API connection timed out ({exc}). "
                f"Proceeding with build using cached justifications.",
                file=sys.stderr,
            )
            return 0
        except Exception as exc:
            print(
                f"::error title=LLM key validation::{type(exc).__name__}: {exc}",
                file=sys.stderr,
            )
            return 1


if __name__ == "__main__":
    sys.exit(main())
