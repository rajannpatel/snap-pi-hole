#!/usr/bin/env python3
"""Validate that GEMINI_API_KEY is set and accepted by the Gemini API.

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
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print(
            "::notice title=Gemini validation::"
            "GEMINI_API_KEY is unavailable (expected for fork PRs). Skipping live key check."
        )
        return 0

    model = os.environ.get("GEMINI_MODEL") or "gemini-flash-latest"
    base_url = (
        os.environ.get("GEMINI_API_BASE_URL")
        or "https://generativelanguage.googleapis.com/v1beta"
    ).rstrip("/")

    url = f"{base_url}/models/{urllib.parse.quote(model, safe='.-_')}:generateContent"
    body = {
        "contents": [{"parts": [{"text": "Reply with exactly the word: ok"}]}],
        "generationConfig": {"responseMimeType": "text/plain"},
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "x-goog-api-key": api_key,
        },
        method="POST",
    )

    max_attempts = max(1, int(os.environ.get("GEMINI_MAX_ATTEMPTS", "3")))
    retry_base_delay = max(0.0, float(os.environ.get("GEMINI_RETRY_BASE_DELAY_SECONDS", "1.0")))

    for attempt in range(1, max_attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            text = (
                data.get("candidates", [{}])[0]
                .get("content", {})
                .get("parts", [{}])[0]
                .get("text", "")
            )
            print(f"Gemini API key is valid. Model responded: {text.strip()!r}")
            return 0
        except urllib.error.HTTPError as exc:
            body_text = ""
            try:
                body_text = exc.read().decode("utf-8", errors="replace").strip()
            except Exception:
                pass
            print(
                f"Gemini key validation HTTP error (attempt {attempt}/{max_attempts}): status {exc.code}. "
                f"Response body: {body_text or '<empty>'}",
                file=sys.stderr,
            )
            if exc.code in {429, 500, 502, 503, 504} and attempt < max_attempts:
                time.sleep(min(retry_base_delay * (2 ** (attempt - 1)), 8.0))
                continue
            if exc.code in {429, 500, 502, 503, 504}:
                print(
                    f"::warning title=Gemini key validation::Gemini API is temporarily unavailable (HTTP {exc.code}). "
                    f"Proceeding with build using cached justifications.",
                    file=sys.stderr,
                )
                return 0
            print(
                f"::error title=Gemini key validation::HTTP {exc.code} from Gemini API. {body_text}",
                file=sys.stderr,
            )
            return 1
        except (urllib.error.URLError, TimeoutError) as exc:
            print(
                f"Gemini key validation network error (attempt {attempt}/{max_attempts}): {exc}",
                file=sys.stderr,
            )
            if attempt < max_attempts:
                time.sleep(min(retry_base_delay * (2 ** (attempt - 1)), 8.0))
                continue
            print(
                f"::warning title=Gemini key validation::Gemini API connection timed out ({exc}). "
                f"Proceeding with build using cached justifications.",
                file=sys.stderr,
            )
            return 0
        except Exception as exc:
            print(
                f"::error title=Gemini key validation::{type(exc).__name__}: {exc}",
                file=sys.stderr,
            )
            return 1


if __name__ == "__main__":
    sys.exit(main())
