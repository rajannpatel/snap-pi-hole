#!/usr/bin/env python3
"""Validate that GEMINI_API_KEY is set and accepted by the Gemini API.

Exits with status 0 on success, 1 on failure.
Emits GitHub Actions workflow commands so failures surface in the CI UI.
"""
import json
import os
import sys
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

    model = os.environ.get("GEMINI_MODEL", "gemini-1.5-flash")
    base_url = os.environ.get(
        "GEMINI_API_BASE_URL", "https://generativelanguage.googleapis.com/v1beta"
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
            f"::error title=Gemini key validation::HTTP {exc.code} from Gemini API. {body_text}",
            file=sys.stderr,
        )
        return 1
    except Exception as exc:
        print(
            f"::error title=Gemini key validation::{type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
