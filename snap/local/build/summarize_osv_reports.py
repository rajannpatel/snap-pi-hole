#!/usr/bin/env python3
import html
import json
import math
import pathlib
import re
import sys
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

from report_assets import vanilla_framework_css_link
from llm_model import select_best_model, DEFAULT_MODEL


def load_cache():
    repo_root = pathlib.Path(__file__).resolve().parent.parent.parent.parent
    cache_file = repo_root / "local-vulnerabilities" / "llm-cache.json"
    if cache_file.exists():
        try:
            return json.loads(cache_file.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"Error loading cache: {e}", file=sys.stderr)
    return {}


def save_cache(cache):
    repo_root = pathlib.Path(__file__).resolve().parent.parent.parent.parent
    cache_file = repo_root / "local-vulnerabilities" / "llm-cache.json"
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    try:
        cache_file.write_text(json.dumps(cache, indent=2) + "\n", encoding="utf-8")
    except Exception as e:
        print(f"Error saving cache: {e}", file=sys.stderr)


PROMPT_TEMPLATE_PATH = (
    pathlib.Path(__file__).resolve().parent / "prompts" / "cve_confinement_analysis.md"
)

PROMPT_BATCH_PLACEHOLDER = "{{CVE_BATCH_JSON}}"
PROMPT_BUILD_PROVENANCE_PLACEHOLDER = "{{BUILD_PROVENANCE}}"

# Read so the model audits against the real build toolchain and packaging
# instead of guessing. The snap is assembled in public GitHub Actions, so these
# facts are verifiable rather than assumed.
SNAPCRAFT_YAML_PATH = (
    pathlib.Path(__file__).resolve().parent.parent.parent / "snapcraft.yaml"
)

# GitHub Models free tier caps a single request body at 8000 input tokens for
# high-tier models (e.g. gpt-4.1). Vulnerabilities are sent in size-limited
# batches so neither the request body nor the response exceeds the per-call
# token limits; otherwise the API rejects the whole batch with HTTP 413.
# Smaller batches give each CVE more room for a thorough, grounded analysis in
# the (output-token-limited) response. All three are env-overridable so depth and
# throughput can be tuned without code edits (e.g. set LLM_MAX_VULNS_PER_BATCH=1
# for maximum per-CVE depth at the cost of more requests).
MAX_BATCH_INPUT_TOKENS = 6500
MAX_VULNS_PER_BATCH = max(1, int(os.environ.get("LLM_MAX_VULNS_PER_BATCH") or "3"))
MAX_DETAILS_CHARS = max(200, int(os.environ.get("LLM_MAX_DETAILS_CHARS") or "1600"))
MAX_REFERENCES = 6
BATCH_PACING_SECONDS = 1.0

# Concise resilience copy used only if the external Markdown template cannot be
# read. The authoritative, editable prompt lives in PROMPT_TEMPLATE_PATH.
FALLBACK_PROMPT_TEMPLATE = """You are acting as a senior DevSecOps Engineer and Infrastructure Security Architect auditing CVEs for snap-pi-hole, a network-wide DNS sinkhole shipped as a strictly confined Ubuntu snap (AppArmor, seccomp, read-only SquashFS). The service answers DNS on port 53 and serves an admin web UI on ports 80 and 443.

Build provenance (verifiable from the public GitHub Actions build; treat as ground truth and use it to dismiss findings that cannot apply to how this snap is actually compiled and shipped):
{{BUILD_PROVENANCE}}

Each finding carries cve, package, version, details, and when available aliases, severity, a fix_available flag with fixed_versions, and reference URLs; treat that as the source of truth. For each finding reason about the real attack vector, whether the vulnerable code is even reachable from the snap's DNS or web services with attacker input (many findings live in command-line, optional, or test-only code the runtime never invokes), whether the sandbox stops a host compromise (it almost always does), and only then what concrete impact remains inside the sandbox. A remotely triggerable crash of the running resolver that breaks network-wide DNS is a real residual risk; speculation about code the snap never runs is not.

Return a single JSON object and nothing else: keys are the exact vulnerability identifiers (every id in the batch must appear as a key — never drop a finding, even one you judge contained or inapplicable), and each value is an object with either or both of two string keys. Always include "appropriate": a thorough, specific case for how snap confinement mitigates the risk (attack vector, reachability, and how AppArmor/seccomp/read-only SquashFS cap the blast radius and block host compromise) — several sentences are welcome when the bug warrants it. Include "not_appropriate" only when a concrete, reachable, material residual risk genuinely remains; omit it entirely for speculative, hypothetical, negligible, or non-shipped-code risks rather than inventing one, and never fill it with a no-risk disclaimer such as "No residual risk", "None", or "N/A" (its absence already signals containment). At least one key must be present per finding. Be specific and evidence-based; no filler, no Markdown, no text outside the JSON object.

Batch data to process:
{{CVE_BATCH_JSON}}
"""


def _parse_snapcraft_platforms(text):
    """Return the target architecture keys listed under ``platforms:``."""
    arches = []
    in_block = False
    for line in text.splitlines():
        if re.match(r"^platforms:\s*$", line):
            in_block = True
            continue
        if in_block:
            match = re.match(r"^[ \t]+([A-Za-z0-9_]+):\s*$", line)
            if match:
                arches.append(match.group(1))
                continue
            # First line that is not an indented arch key ends the block.
            if line.strip() and not line[0].isspace():
                break
    return arches


def _snapcraft_build_facts():
    """Extract a few verifiable build facts from snapcraft.yaml.

    Falls back to the committed defaults so the prompt still carries accurate
    provenance if the file moves or a field is renamed.
    """
    facts = {
        "base": "core26",
        "confinement": "strict",
        "build_type": "Release",
        "linking": "dynamically linked",
        "architectures": "amd64, arm64, armhf, ppc64el, s390x, riscv64",
    }
    try:
        text = SNAPCRAFT_YAML_PATH.read_text(encoding="utf-8")
    except OSError:
        return facts

    base = re.search(r"(?m)^base:\s*(\S+)", text)
    if base:
        facts["base"] = base.group(1)
    confinement = re.search(r"(?m)^confinement:\s*(\S+)", text)
    if confinement:
        facts["confinement"] = confinement.group(1)
    build_type = re.search(r"-DCMAKE_BUILD_TYPE=(\w+)", text)
    if build_type:
        facts["build_type"] = build_type.group(1)
    static = re.search(r"-DSTATIC=(\w+)", text)
    if static:
        facts["linking"] = (
            "statically linked"
            if static.group(1).lower() == "true"
            else "dynamically linked"
        )
    arches = _parse_snapcraft_platforms(text)
    if arches:
        facts["architectures"] = ", ".join(arches)
    return facts


def build_provenance_block():
    """Render the build-and-runtime provenance the model audits against."""
    f = _snapcraft_build_facts()
    return "\n".join(
        [
            "- Build system: the snap is assembled by snapcraft on GitHub-hosted "
            "Ubuntu runners in GitHub Actions. The build configuration is public "
            "and reproducible, so the facts below are verifiable from the build "
            "itself rather than assumed \u2014 rely on them as ground truth.",
            f"- Base and confinement: built on the `{f['base']}` base under "
            f"`{f['confinement']}` confinement (AppArmor, seccomp, and a "
            "read-only SquashFS root).",
            "- Compiled-from-source component: only the C daemon `pihole-FTL` "
            "(the DNS/DHCP/API/embedded web server, with a vendored dnsmasq) is "
            f"compiled here, via CMake ({f['build_type']} build, {f['linking']}) "
            "with the build environment's standard GNU toolchain (GCC / "
            "build-essential). It is not built with LLVM/Clang, so "
            "Clang/LLVM-specific codegen issues (for example select-optimize "
            "side-channels) cannot apply to it.",
            "- Interpreted components: the Pi-hole core CLI is POSIX shell and "
            "the web admin UI is PHP/JS/CSS assets; neither is compiled, so "
            "C/C++ memory-safety vulnerability classes cannot apply to them.",
            "- Third-party libraries (for example mbedTLS, nettle, sqlite3, "
            "libidn2, libuv, readline, coreutils, jq) are staged as pre-built "
            "binaries from the Ubuntu archive for this base; this project does "
            "not recompile them, so their machine code follows Canonical's "
            "standard archive build (GCC), not a custom or LLVM toolchain.",
            f"- Target architectures: {f['architectures']}.",
        ]
    )


def load_prompt_template():
    try:
        text = PROMPT_TEMPLATE_PATH.read_text(encoding="utf-8")
        # Strip HTML maintainer comments so they are not sent to the model and so
        # a placeholder mentioned inside a comment is not substituted twice.
        text = re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL).strip()
    except OSError as exc:
        print(
            f"Could not read prompt template at {PROMPT_TEMPLATE_PATH}: {exc}. "
            "Falling back to the built-in prompt.",
            file=sys.stderr,
        )
        text = FALLBACK_PROMPT_TEMPLATE
    # Resolve the build-provenance placeholder up front so every consumer (prompt
    # assembly and batch-overhead estimation) sees the real build facts; only the
    # per-batch CVE placeholder remains for the caller to fill.
    return text.replace(
        PROMPT_BUILD_PROVENANCE_PLACEHOLDER, build_provenance_block()
    )


def _estimate_tokens(text):
    """Rough token estimate (~4 chars/token) used only to size request batches."""
    return (len(text) + 3) // 4


def _truncate_details(details):
    text = str(details or "").strip()
    if len(text) <= MAX_DETAILS_CHARS:
        return text
    return text[:MAX_DETAILS_CHARS].rstrip() + "\u2026"


def _extract_references(vuln_obj, limit=MAX_REFERENCES):
    """Collect up to ``limit`` distinct reference URLs from an OSV record."""
    urls = []
    for ref in vuln_obj.get("references") or []:
        url = ref.get("url") if isinstance(ref, dict) else None
        if url and url not in urls:
            urls.append(url)
        if len(urls) >= limit:
            break
    return urls


def _extract_fixed_versions(vuln_obj):
    """Collect distinct fixed versions from an OSV record's affected ranges.

    A populated list signals that an upstream fix exists, which is material
    grounding for the model when it weighs a confined-mitigation label.
    """
    fixed = []
    for affected in vuln_obj.get("affected") or []:
        for rng in affected.get("ranges") or []:
            for event in rng.get("events") or []:
                version = event.get("fixed") if isinstance(event, dict) else None
                if version and version not in fixed:
                    fixed.append(version)
    return fixed


def _batch_entry(vuln):
    """Build the per-CVE payload sent to the model, including grounding fields.

    Optional fields (aliases, severity, references, fixed versions) are included
    only when present so callers that supply a minimal vuln dict stay lean.
    """
    entry = {
        "cve": vuln["cve_id"],
        "package": vuln.get("package_name", ""),
        "version": vuln.get("version", ""),
        "details": _truncate_details(vuln.get("details", "")),
    }
    aliases = [a for a in (vuln.get("aliases") or []) if a]
    if aliases:
        entry["aliases"] = aliases[:8]
    severity = (vuln.get("severity") or "").strip()
    if severity:
        entry["severity"] = severity
    fixed_versions = [f for f in (vuln.get("fixed_versions") or []) if f]
    if fixed_versions:
        entry["fix_available"] = True
        entry["fixed_versions"] = fixed_versions
    references = [r for r in (vuln.get("references") or []) if r]
    if references:
        entry["references"] = references[:MAX_REFERENCES]
    return entry


def build_analysis_prompt(vulns_to_query):
    batch_payload = [_batch_entry(v) for v in vulns_to_query]
    batch_json = json.dumps(batch_payload, indent=2, ensure_ascii=False)
    return load_prompt_template().replace(PROMPT_BATCH_PLACEHOLDER, batch_json)


def iter_vuln_batches(vulns_to_query):
    """Split vulnerabilities into batches that fit the per-request token budget."""
    template = load_prompt_template()
    overhead = _estimate_tokens(template.replace(PROMPT_BATCH_PLACEHOLDER, ""))
    batch_budget = max(500, MAX_BATCH_INPUT_TOKENS - overhead)
    chunk = []
    chunk_tokens = 0
    for vuln in vulns_to_query:
        entry_tokens = _estimate_tokens(json.dumps(_batch_entry(vuln), indent=2, ensure_ascii=False))
        too_many = len(chunk) >= MAX_VULNS_PER_BATCH
        too_big = bool(chunk) and (chunk_tokens + entry_tokens) > batch_budget
        if chunk and (too_many or too_big):
            yield chunk
            chunk = []
            chunk_tokens = 0
        chunk.append(vuln)
        chunk_tokens += entry_tokens
    if chunk:
        yield chunk


LLM_LOOKUP_ERROR_TEXT = "error during LLM lookup"


def is_failed_explanation(explanation):
    """Return True when an explanation is a lookup-failure placeholder.

    Failure placeholders are never written to the cache, and any that already
    exist there are treated as a cache miss and re-queried, so a transient
    outage cannot permanently replace real analysis with an error message.

    Either section may legitimately be empty (the model omits a section when it
    has nothing substantive to say), but an explanation with no populated
    section at all, or one carrying the error text, counts as a failure.
    """
    if not isinstance(explanation, dict):
        return True
    appropriate = str(explanation.get("appropriate", "") or "")
    not_appropriate = str(explanation.get("not_appropriate", "") or "")
    if LLM_LOOKUP_ERROR_TEXT in appropriate or LLM_LOOKUP_ERROR_TEXT in not_appropriate:
        return True
    return not appropriate.strip() and not not_appropriate.strip()


_NO_RESIDUAL_RISK_RE = re.compile(
    r"^\W*(?:"
    r"no\b[^.;:]*\bresidual risk"
    r"|no\b[^.;:]*\b(?:additional|further|meaningful|concrete|practical|realistic"
    r"|material|significant|net|extra|added|genuine|real|actual)\b[^.;:]*\brisk"
    r"|there (?:is|are) no\b[^.;:]*\brisk"
    r"|none\b"
    r"|n/?a\b"
    r"|not applicable\b"
    r")",
    re.IGNORECASE,
)


def _is_no_residual_risk_note(text):
    """True when a ``not_appropriate`` value actually asserts there is no risk.

    The model is told to omit the residual-risk section entirely when nothing
    concrete remains, but it sometimes fills it with a "No concrete residual
    risk: ..." disclaimer instead. Such a value is treated as empty so the report
    shows the contained recommendation rather than a self-contradicting
    residual-risk section.
    """
    return bool(_NO_RESIDUAL_RISK_RE.match((text or "").strip()))


def coerce_explanation(item):
    """Normalize a model-supplied explanation to a {appropriate, not_appropriate} dict.

    Either key may be missing or empty; the omitted section is stored as an
    empty string so downstream rendering can skip it. A ``not_appropriate`` value
    that merely states there is no residual risk is dropped (the model should have
    omitted it). Returns None when the item is not a dict or carries no usable
    content in either section.
    """
    if not isinstance(item, dict):
        return None
    appropriate = str(item.get("appropriate", "") or "").strip()
    not_appropriate = str(item.get("not_appropriate", "") or "").strip()
    if not_appropriate and _is_no_residual_risk_note(not_appropriate):
        not_appropriate = ""
    if not appropriate and not not_appropriate:
        return None
    return {"appropriate": appropriate, "not_appropriate": not_appropriate}


CONFINEMENT_CONTAINED = "contained"
CONFINEMENT_RESIDUAL = "residual"
CONFINEMENT_RECOMMENDATION_LABELS = {
    CONFINEMENT_CONTAINED: "\u2713 Contained by confinement",
    CONFINEMENT_RESIDUAL: "\u26a0 Residual risk beyond confinement",
}


def confinement_recommendation(appropriate_text, not_appropriate_text):
    """Derive a binary confinement recommendation from section presence.

    Returns CONFINEMENT_CONTAINED when only the mitigation case is present,
    CONFINEMENT_RESIDUAL when a residual-risk section remains, or None when the
    analysis is missing or carries the lookup-error placeholder, so a failed
    lookup never renders a misleading recommendation.
    """
    appropriate = (appropriate_text or "").strip()
    not_appropriate = (not_appropriate_text or "").strip()
    if LLM_LOOKUP_ERROR_TEXT in appropriate or LLM_LOOKUP_ERROR_TEXT in not_appropriate:
        return None
    if not_appropriate:
        return CONFINEMENT_RESIDUAL
    if appropriate:
        return CONFINEMENT_CONTAINED
    return None


def query_llm_vulnerabilities_batch(vulns_to_query, model=None):
    if not vulns_to_query:
        return {}

    api_key = os.environ.get("LLM_API_KEY")
    if not api_key:
        print("LLM_API_KEY not set. Using fallback placeholders for batch vulnerabilities.", file=sys.stderr)
        return {
            v["cve_id"]: {
                "appropriate": (
                    "Snap confinement (AppArmor, seccomp, and a read-only SquashFS root) "
                    f"restricts process capabilities and host access, containing {v['cve_id']} "
                    "within the sandbox so it cannot compromise the host."
                ),
            }
            for v in vulns_to_query
        }

    model = model or DEFAULT_MODEL
    batches = list(iter_vuln_batches(vulns_to_query))
    results = {}
    for index, batch in enumerate(batches):
        if index > 0 and BATCH_PACING_SECONDS > 0:
            time.sleep(BATCH_PACING_SECONDS)
        if len(batches) > 1:
            print(
                f"Querying LLM batch {index + 1}/{len(batches)} ({len(batch)} vulnerabilities)...",
                file=sys.stderr,
            )
        results.update(_query_vuln_batch_once(batch, model, api_key))

    # Salvage pass: a finding can come back failed or omitted when its batch's
    # combined JSON is truncated or the model drops an id it considers a
    # non-issue. Re-query each straggler on its own, where it gets the full
    # output-token budget and a neighbour's parse error cannot take it down. This
    # only splits genuine multi-finding batches; a lone finding already exhausted
    # its retries in _query_vuln_batch_once.
    if len(vulns_to_query) > 1:
        by_id = {v["cve_id"]: v for v in vulns_to_query}
        failed_ids = [
            cid for cid in by_id if is_failed_explanation(results.get(cid))
        ]
        for cid in failed_ids:
            if BATCH_PACING_SECONDS > 0:
                time.sleep(BATCH_PACING_SECONDS)
            print(
                f"Re-querying {cid} individually after a batch miss...",
                file=sys.stderr,
            )
            salvaged = _query_vuln_batch_once([by_id[cid]], model, api_key)
            if not is_failed_explanation(salvaged.get(cid)):
                results[cid] = salvaged[cid]
    return results


def _query_vuln_batch_once(vulns_to_query, model, api_key):
    base_url = (os.environ.get("LLM_API_BASE_URL") or "https://models.github.ai/inference").rstrip("/")
    max_attempts = max(1, int(os.environ.get("LLM_MAX_ATTEMPTS") or "3"))
    retry_base_delay = max(0.0, float(os.environ.get("LLM_RETRY_BASE_DELAY_SECONDS") or "1.0"))

    prompt = build_analysis_prompt(vulns_to_query)

    url = f"{base_url}/chat/completions"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    }
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "response_format": {"type": "json_object"},
        "max_tokens": max(256, int(os.environ.get("LLM_MAX_OUTPUT_TOKENS") or "4000")),
    }

    fallback_map = {
        v["cve_id"]: {
            "appropriate": LLM_LOOKUP_ERROR_TEXT,
            "not_appropriate": LLM_LOOKUP_ERROR_TEXT
        }
        for v in vulns_to_query
    }

    def normalize_explanations(payload):
        if not isinstance(payload, dict):
            raise ValueError("LLM response payload is not an object")
        if len(vulns_to_query) == 1 and vulns_to_query[0]["cve_id"] not in payload:
            direct = coerce_explanation(payload)
            if direct is not None:
                return {vulns_to_query[0]["cve_id"]: direct}
        res = {}
        for v in vulns_to_query:
            cve_id = v["cve_id"]
            coerced = coerce_explanation(payload.get(cve_id))
            res[cve_id] = coerced if coerced is not None else fallback_map[cve_id]
        return res

    def parse_text_payload(text):
        stripped = str(text or "").strip()
        if not stripped:
            raise ValueError("LLM response text is empty")
        try:
            return normalize_explanations(json.loads(stripped))
        except json.JSONDecodeError:
            pass

        if stripped.startswith("```"):
            stripped = stripped.strip("`")
            if stripped.lower().startswith("json"):
                stripped = stripped[4:].lstrip()
            try:
                return normalize_explanations(json.loads(stripped))
            except json.JSONDecodeError:
                pass

        start = stripped.find("{")
        end = stripped.rfind("}")
        if start != -1 and end != -1 and start < end:
            candidate = stripped[start:end + 1]
            return normalize_explanations(json.loads(candidate))
        raise ValueError("Unable to parse LLM JSON payload")

    def parse_llm_response(raw_payload):
        choices = raw_payload.get("choices", []) if isinstance(raw_payload, dict) else []
        if choices:
            text = choices[0].get("message", {}).get("content", "")
            return parse_text_payload(text)
        raise ValueError("No parseable LLM response content")

    # Retry loop
    for attempt in range(1, max_attempts + 1):
        try:
            req = urllib.request.Request(
                url,
                data=json.dumps(body).encode("utf-8"),
                headers=headers,
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=45) as response:
                resp_data = json.loads(response.read().decode("utf-8"))
                return parse_llm_response(resp_data)
        except urllib.error.HTTPError as exc:
            response_body = ""
            try:
                response_body = exc.read().decode("utf-8", errors="replace").strip()
            except Exception:
                response_body = ""
            print(
                f"LLM API HTTP error for batch query (attempt {attempt}/{max_attempts}): status {exc.code}. "
                f"Response body: {response_body or '<empty>'}",
                file=sys.stderr,
            )
            if exc.code in {429, 500, 502, 503, 504} and attempt < max_attempts:
                sleep_delay = None
                if exc.code == 429:
                    resp_headers = exc.headers or {}
                    retry_after = resp_headers.get("Retry-After")
                    if retry_after:
                        try:
                            sleep_delay = max(2.0, float(retry_after) + 0.5)
                            print(
                                f"Rate limit detected for batch query. Sleeping for {sleep_delay:.2f}s via Retry-After header.",
                                file=sys.stderr,
                            )
                        except ValueError:
                            pass
                    if sleep_delay is None:
                        reset_time = resp_headers.get("x-ratelimit-reset") or resp_headers.get("X-RateLimit-Reset")
                        if reset_time:
                            try:
                                sleep_delay = max(2.0, float(reset_time) - time.time() + 1.0)
                                print(
                                    f"Rate limit detected for batch query. Sleeping for {sleep_delay:.2f}s via x-ratelimit-reset header.",
                                    file=sys.stderr,
                                )
                            except ValueError:
                                pass
                    if sleep_delay is None and response_body:
                        match = re.search(r"(?:retry in|try again in|retry after) (\d+\.?\d*)(?:\s*s|\s*second)", response_body, re.IGNORECASE)
                        if match:
                            try:
                                sleep_delay = max(2.0, float(match.group(1)) + 0.5)
                                print(
                                    f"Rate limit detected for batch query. Sleeping for {sleep_delay:.2f}s via response body.",
                                    file=sys.stderr,
                                )
                            except ValueError:
                                pass
                if sleep_delay is None:
                    cap = 30.0 if exc.code == 429 else 8.0
                    sleep_delay = max(2.0, min(retry_base_delay * (2 ** (attempt - 1)), cap)) if exc.code == 429 else min(retry_base_delay * (2 ** (attempt - 1)), cap)
                time.sleep(sleep_delay)
                continue
            break
        except urllib.error.URLError as exc:
            print(f"LLM API connection error for batch query: {exc}.", file=sys.stderr)
            if attempt < max_attempts:
                time.sleep(min(retry_base_delay * (2 ** (attempt - 1)), 8.0))
                continue
            break
        except (json.JSONDecodeError, KeyError, IndexError, ValueError) as exc:
            print(f"LLM API response parsing error for batch query: {exc}.", file=sys.stderr)
            if attempt < max_attempts:
                time.sleep(min(retry_base_delay * (2 ** (attempt - 1)), 8.0))
                continue
            break
        except Exception as exc:
            print(f"Unexpected LLM lookup error for batch query: {type(exc).__name__}: {exc}.", file=sys.stderr)
            break
    return fallback_map


def query_vulnerability_info(cve_id, package_name, version, details="", model=None):
    res = query_llm_vulnerabilities_batch([{
        "cve_id": cve_id,
        "package_name": package_name,
        "version": version,
        "details": details,
    }], model=model)
    return res.get(cve_id, {
        "appropriate": LLM_LOOKUP_ERROR_TEXT,
        "not_appropriate": LLM_LOOKUP_ERROR_TEXT
    })



SEVERITY_ICONS = {
    "critical": "https://assets.ubuntu.com/v1/c96f27b9-CVE-Priority-icon-Critical.svg",
    "high": "https://assets.ubuntu.com/v1/3887354e-CVE-Priority-icon-High.svg",
    "medium": "https://assets.ubuntu.com/v1/8010f9e0-CVE-Priority-icon-Medium.svg",
    "low": "https://assets.ubuntu.com/v1/03ac6f86-CVE-Priority-icon-Low.svg",
    "negligible": "https://assets.ubuntu.com/v1/f6820eae-CVE-Priority-icon-Negligible.svg",
    "unknown": "https://assets.ubuntu.com/v1/e85d00c8-CVE-Priority-icon-Unknown.svg",
}


CVSS3_METRICS = {
    "AV": {"N": 0.85, "A": 0.62, "L": 0.55, "P": 0.2},
    "AC": {"L": 0.77, "H": 0.44},
    "UI": {"N": 0.85, "R": 0.62},
    "S": {"U": "U", "C": "C"},
    "C": {"H": 0.56, "L": 0.22, "N": 0.0},
    "I": {"H": 0.56, "L": 0.22, "N": 0.0},
    "A": {"H": 0.56, "L": 0.22, "N": 0.0},
}


CVSS3_PR = {
    "U": {"N": 0.85, "L": 0.62, "H": 0.27},
    "C": {"N": 0.85, "L": 0.68, "H": 0.5},
}


def vuln_url(vulnerability):
    references = vulnerability.get("references", [])
    for ref in references:
        url = ref.get("url")
        if url:
            return url
    vuln_id = vulnerability.get("id")
    if vuln_id:
        return f"https://osv.dev/vulnerability/{vuln_id}"
    return ""


def cvss3_round_up(score):
    return math.ceil(score * 10) / 10


def cvss3_base_score(vector):
    metrics = {}
    for part in vector.split("/"):
        if part.startswith("CVSS:"):
            continue
        if ":" in part:
            key, value = part.split(":", 1)
            metrics[key] = value

    try:
        scope = CVSS3_METRICS["S"][metrics["S"]]
        iss = 1 - (
            (1 - CVSS3_METRICS["C"][metrics["C"]])
            * (1 - CVSS3_METRICS["I"][metrics["I"]])
            * (1 - CVSS3_METRICS["A"][metrics["A"]])
        )
        impact = (
            6.42 * iss
            if scope == "U"
            else 7.52 * (iss - 0.029) - 3.25 * ((iss - 0.02) ** 15)
        )
        exploitability = (
            8.22
            * CVSS3_METRICS["AV"][metrics["AV"]]
            * CVSS3_METRICS["AC"][metrics["AC"]]
            * CVSS3_PR[scope][metrics["PR"]]
            * CVSS3_METRICS["UI"][metrics["UI"]]
        )
    except KeyError:
        return None

    if impact <= 0:
        return 0.0

    if scope == "U":
        score = min(impact + exploitability, 10)
    else:
        score = min(1.08 * (impact + exploitability), 10)

    return cvss3_round_up(score)


def cvss3_rating(score):
    if score is None:
        return "Unknown"
    if score == 0:
        return "None"
    if score < 4.0:
        return "Low"
    if score < 7.0:
        return "Medium"
    if score < 9.0:
        return "High"
    return "Critical"


def cvss3_severity_text(vulnerability):
    scored_vectors = []
    for severity in vulnerability.get("severity", []):
        if severity.get("type") != "CVSS_V3":
            continue
        vector = severity.get("score", "")
        score = cvss3_base_score(vector)
        if score is not None:
            scored_vectors.append((score, vector))

    if not scored_vectors:
        return "Unknown"

    score, _vector = max(scored_vectors)
    return f"{score:.1f} · {cvss3_rating(score)}"


def ubuntu_priority(vulnerability):
    for severity in vulnerability.get("severity", []):
        if severity.get("type") == "Ubuntu" and severity.get("score"):
            return severity["score"].lower()

    database_specific = vulnerability.get("database_specific", {})
    severity_value = database_specific.get("severity")
    if severity_value:
        return str(severity_value).lower()

    return "unknown"


def severity_priority(severity):
    severity_lower = severity.lower()
    for priority in ("critical", "high", "medium", "low", "negligible"):
        if priority in severity_lower:
            return priority
    return "unknown"


def status_chip(text, priority, alt):
    icon_priority = priority if priority in SEVERITY_ICONS else "unknown"
    visible_text = text.upper()
    return (
        '<span class="p-chip vulnerability-severity">'
        '<span class="p-chip__value">'
        f'<img src="{SEVERITY_ICONS[icon_priority]}" '
        f'alt="{html.escape(alt)}" '
        f'title="{html.escape(text)}" '
        'style="height: 14px; width: 14px; vertical-align: text-bottom; margin-right: 0.25rem;">'
        f'{html.escape(visible_text)}'
        '</span>'
        '</span>'
    )


def severity_icon(severity):
    priority = severity_priority(severity)
    return status_chip(severity, priority, f"{severity} severity")


def priority_icon(priority):
    priority_value = priority.lower()
    return status_chip(priority_value, priority_value, f"{priority_value} priority")


def display_vulnerability_id(vulnerability_id):
    return vulnerability_id.removeprefix("UBUNTU-")


def normalize_architecture_label(architecture):
    arch = str(architecture).strip().lower()
    if arch == "amd64":
        return "AMD64"
    if arch == "arm64":
        return "ARM64"
    return arch.upper()


def format_publication_date(value):
    text_value = str(value or "").strip()
    if not text_value:
        return "", "Unknown"

    normalized = text_value.replace("Z", "+00:00")
    try:
        published_at = datetime.fromisoformat(normalized)
    except ValueError:
        return text_value, text_value

    if published_at.tzinfo is None:
        published_at = published_at.replace(tzinfo=timezone.utc)

    published_utc = published_at.astimezone(timezone.utc)
    return (
        published_utc.isoformat(timespec="seconds").replace("+00:00", "Z"),
        published_utc.strftime("%Y-%m-%d"),
    )


def architecture_chip(architecture):
    return (
        '<span class="p-chip vulnerability-architecture">'
        f'<span class="p-chip__value">{html.escape(normalize_architecture_label(architecture))}</span>'
        "</span>"
    )


def vulnerability_entry(vulnerability, patchable):
    aliases = vulnerability.get("aliases", [])
    return {
        "id": vulnerability.get("id", "unknown"),
        "aliases": aliases,
        "summary": vulnerability.get("summary", ""),
        "details": vulnerability.get("details", ""),
        "severity": cvss3_severity_text(vulnerability),
        "priority": ubuntu_priority(vulnerability),
        "published": vulnerability.get("published", ""),
        "modified": vulnerability.get("modified", ""),
        "url": vuln_url(vulnerability),
        "patchable": patchable,
    }


def markdown_cell(value):
    return str(value).replace("|", "\\|").replace("\n", " ").strip()


def generated_time(report_path):
    generated_at = datetime.fromtimestamp(report_path.stat().st_mtime, timezone.utc)
    return {
        "datetime": generated_at.isoformat(timespec="seconds").replace("+00:00", "Z"),
        "label": generated_at.strftime("%Y-%m-%d %H:%M UTC"),
    }


def collect_reports(reports_dir):
    summary = {
        "reports": [],
        "totalVulnerabilities": 0,
        "affectedPackages": 0,
        "actionableVulnerabilities": 0,
        "actionableAffectedPackages": 0,
        "confinedMitigationVulnerabilities": 0,
    }

    cache = load_cache()
    cache_updated = False
    # Explanations fetched during this run (including failures), so a stale or
    # failed cache entry is not re-queried per CVE after the batch pre-scan.
    runtime_explanations = {}
    # Resolved once (if any live lookups are needed) to the best model the CI
    # token can call; see select_best_model.
    selected_model = None

    # Discovery pre-scan: find all uncached vulnerabilities to fetch in a single batch request
    uncached_vulns_to_query = []
    seen_uncached = set()
    for report_path in sorted(reports_dir.glob("osv-*.json")):
        if report_path.name == "osv-summary.json":
            continue
        try:
            data = json.loads(report_path.read_text(encoding="utf-8"))
        except Exception:
            continue
        for result in data.get("results", []):
            for package in result.get("packages", []):
                vulns = package.get("vulnerabilities", [])
                if not vulns:
                    continue
                pkg = package.get("package", {})
                package_name = pkg.get("name", "unknown")
                package_version = pkg.get("version", "")
                for v in vulns:
                    vuln_id = v.get("id", "")
                    cached = cache.get(vuln_id)
                    needs_query = cached is None or is_failed_explanation(cached)
                    if vuln_id and needs_query and vuln_id not in seen_uncached:
                        uncached_vulns_to_query.append({
                            "cve_id": vuln_id,
                            "package_name": package_name,
                            "version": package_version,
                            "details": (v.get("details") or v.get("summary") or "").strip(),
                            "aliases": v.get("aliases", []),
                            "severity": cvss3_severity_text(v),
                            "references": _extract_references(v),
                            "fixed_versions": _extract_fixed_versions(v),
                        })
                        seen_uncached.add(vuln_id)

    api_key = os.environ.get("LLM_API_KEY")
    if uncached_vulns_to_query and api_key:
        selected_model = select_best_model(api_key)
        print(f"Selected LLM model for analysis: {selected_model}", file=sys.stderr)

    if uncached_vulns_to_query:
        print(f"Querying LLM in batch for {len(uncached_vulns_to_query)} uncached vulnerabilities...", file=sys.stderr)
        batch_results = query_llm_vulnerabilities_batch(uncached_vulns_to_query, model=selected_model)
        for vuln_id, explanations in batch_results.items():
            runtime_explanations[vuln_id] = explanations
            if api_key and not is_failed_explanation(explanations):
                cache[vuln_id] = explanations
                cache_updated = True

    for report_path in sorted(reports_dir.glob("osv-*.json")):
        if report_path.name == "osv-summary.json":
            continue
        arch = report_path.stem.removeprefix("osv-")
        data = json.loads(report_path.read_text(encoding="utf-8"))
        vulnerabilities = 0
        affected_packages = 0
        actionable_vulnerabilities = 0
        actionable_affected_packages = 0
        confined_mitigation_vulnerabilities = 0
        entries = []

        for result in data.get("results", []):
            for package in result.get("packages", []):
                vulns = package.get("vulnerabilities", [])
                if not vulns:
                    continue
                pkg = package.get("package", {})
                package_name = pkg.get("name", "unknown")
                package_version = pkg.get("version", "")

                package_vulns = []
                for v in vulns:
                    vuln_id = v.get("id", "")
                    aliases = v.get("aliases", [])
                    related = v.get("related", [])
                    references = v.get("references", [])
                    has_usn = (
                        vuln_id.startswith("USN-")
                        or any(a.startswith("USN-") for a in aliases)
                        or any(r.startswith("USN-") for r in related)
                        or any("/USN-" in ref.get("url", "") or "/notices/USN-" in ref.get("url", "") for ref in references)
                    )
                    
                    explanations = cache.get(vuln_id)
                    if explanations is None or is_failed_explanation(explanations):
                        explanations = runtime_explanations.get(vuln_id)
                    if explanations is None:
                        explanations = query_vulnerability_info(
                            vuln_id,
                            package_name,
                            package_version,
                            (v.get("summary") or v.get("details") or "").strip(),
                            model=selected_model,
                        )
                        runtime_explanations[vuln_id] = explanations
                        if not is_failed_explanation(explanations):
                            cache[vuln_id] = explanations
                            cache_updated = True
                        # Pacing delay to avoid hitting rate limits when processing multiple uncached CVEs
                        time.sleep(1.0)

                    v_entry = vulnerability_entry(v, has_usn)
                    v_entry["appropriate"] = explanations.get("appropriate", "")
                    v_entry["not_appropriate"] = explanations.get("not_appropriate", "")
                    package_vulns.append(v_entry)

                affected_packages += 1
                vulnerabilities += len(package_vulns)
                package_actionable_vulnerabilities = sum(1 for vuln in package_vulns if vuln["patchable"])
                actionable_vulnerabilities += package_actionable_vulnerabilities
                confined_mitigation_vulnerabilities += len(package_vulns) - package_actionable_vulnerabilities
                if package_actionable_vulnerabilities:
                    actionable_affected_packages += 1
                entries.append({
                    "name": package_name,
                    "version": package_version,
                    "ecosystem": pkg.get("ecosystem", ""),
                    "vulnerabilities": package_vulns,
                })

        summary["reports"].append({
            "architecture": arch,
            "report": report_path.name,
            "generatedAt": generated_time(report_path),
            "affectedPackages": affected_packages,
            "vulnerabilities": vulnerabilities,
            "actionableAffectedPackages": actionable_affected_packages,
            "actionableVulnerabilities": actionable_vulnerabilities,
            "confinedMitigationVulnerabilities": confined_mitigation_vulnerabilities,
            "packages": entries,
        })

    # Calculate unique global counts across all architectures
    unique_vulns = set()
    unique_packages = set()
    unique_actionable_vulns = set()
    unique_actionable_packages = set()
    for report in summary["reports"]:
        for package in report["packages"]:
            unique_packages.add(package["name"])
            for vuln in package["vulnerabilities"]:
                unique_vulns.add(vuln["id"])
                if vuln["patchable"]:
                    unique_actionable_vulns.add(vuln["id"])
                    unique_actionable_packages.add(package["name"])
    summary["totalVulnerabilities"] = len(unique_vulns)
    summary["affectedPackages"] = len(unique_packages)
    summary["actionableVulnerabilities"] = len(unique_actionable_vulns)
    summary["actionableAffectedPackages"] = len(unique_actionable_packages)
    summary["confinedMitigationVulnerabilities"] = max(
        0,
        summary["totalVulnerabilities"] - summary["actionableVulnerabilities"],
    )

    if cache_updated:
        save_cache(cache)

    return summary

def write_markdown(summary, output_path):
    lines = [
        "# Vulnerability Summary",
        "",
        "All available security updates are automatically applied during compilation at build time.",
        "Dashboard totals count only actionable vulnerabilities with a corresponding Ubuntu Security Notice (USN).",
        "Raw OSV matches without a USN are retained as confined-mitigation report-only findings for audit visibility.",
        "The CI workflow currently treats OSV exit code 1 as a warning and fails only if the scan itself errors.",
        "",
    ]

    for report in summary["reports"]:
        lines.extend([
            f"## {report['architecture']}",
            "",
            f"- Actionable USN packages: {report['actionableAffectedPackages']}",
            f"- Actionable USN vulnerabilities: {report['actionableVulnerabilities']}",
            f"- Raw OSV affected packages: {report['affectedPackages']}",
            f"- Raw OSV vulnerability matches: {report['vulnerabilities']}",
            f"- Confined-mitigation report-only matches: {report['confinedMitigationVulnerabilities']}",
            f"- JSON report: `{report['report']}`",
            "",
        ])

        if report["packages"]:
            lines.append("| Package | Version | Vulnerability | CVSS 3 | Priority | Status | Published |")
            lines.append("| --- | --- | --- | --- | --- | --- | --- |")
            for package in report["packages"]:
                for vulnerability in package["vulnerabilities"]:
                    vuln_label = display_vulnerability_id(vulnerability["id"])
                    if vulnerability["url"]:
                        vuln_label = f"[{vuln_label}]({vulnerability['url']})"
                    _iso, pub_label = format_publication_date(
                        vulnerability.get("published") or vulnerability.get("modified")
                    )
                    status_str = "Actionable (USN)" if vulnerability["patchable"] else "Confined Mitigation"
                    lines.append(
                        f"| {markdown_cell(package['name'])} | {markdown_cell(package['version'])} | "
                        f"{markdown_cell(vuln_label)} | "
                        f"{markdown_cell(vulnerability['severity'])} | "
                        f"{markdown_cell(vulnerability['priority'])} | "
                        f"{status_str} | "
                        f"{markdown_cell(pub_label)} |"
                    )
            lines.append("")
        else:
            lines.extend(["No unpatched vulnerabilities reported by OSV-Scanner.", ""])

    # Append Confinement Analysis itemization
    has_vulns = False
    for report in summary["reports"]:
        if report["packages"]:
            has_vulns = True
            break
    
    if has_vulns:
        lines.extend([
            "## Confinement Analysis",
            "",
            "Itemized security analysis of identified vulnerabilities and their exposure inside the strictly confined snap sandbox.",
            ""
        ])
        
        seen_vulns = {}
        for report in summary["reports"]:
            for package in report["packages"]:
                for vulnerability in package["vulnerabilities"]:
                    vuln_id = vulnerability["id"]
                    if vuln_id not in seen_vulns:
                        seen_vulns[vuln_id] = {
                            "package": package["name"],
                            "version": package["version"],
                            "appropriate": vulnerability.get("appropriate", ""),
                            "not_appropriate": vulnerability.get("not_appropriate", "")
                        }
        
        for vuln_id, info in sorted(seen_vulns.items()):
            vuln_label = display_vulnerability_id(vuln_id)
            lines.extend([
                f"### {vuln_label} ({info['package']})",
                "",
            ])
            appropriate_text = (info.get("appropriate") or "").strip()
            not_appropriate_text = (info.get("not_appropriate") or "").strip()
            recommendation = confinement_recommendation(appropriate_text, not_appropriate_text)
            if recommendation:
                lines.append(f"**{CONFINEMENT_RECOMMENDATION_LABELS[recommendation]}**")
                lines.append("")
            if appropriate_text:
                lines.append("- **Snap confinement mitigates risk**:")
                lines.append(f"  {appropriate_text}")
            if not_appropriate_text:
                lines.append("- **Risk boundary extends beyond snap confinement**:")
                lines.append(f"  {not_appropriate_text}")
            lines.append("")

    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def status_badge(patchable):
    if patchable:
        return (
            '<span class="p-chip" style="background-color: #e6f2ff; border: 1px solid #b3d7ff; color: #004085;">'
            '<span class="p-chip__value">Actionable (USN)</span>'
            '</span>'
        )
    else:
        return (
            '<span class="p-chip" style="background-color: #f3e5f5; border: 1px solid #e1bee7; color: #4a148c;" title="Mitigated by snap confinement">'
            '<span class="p-chip__value">Confined Mitigation</span>'
            '</span>'
        )


def confinement_recommendation_badge(recommendation):
    if recommendation == CONFINEMENT_CONTAINED:
        return (
            '<span class="p-chip" style="background-color: #e8f5e9; border: 1px solid #a5d6a7; color: #1b5e20;" title="No residual risk remains beyond snap confinement">'
            '<span class="p-chip__value">\u2713 Contained by confinement</span>'
            '</span>'
        )
    if recommendation == CONFINEMENT_RESIDUAL:
        return (
            '<span class="p-chip" style="background-color: #fff3e0; border: 1px solid #ffcc80; color: #e65100;" title="Residual risk extends beyond snap confinement">'
            '<span class="p-chip__value">\u26a0 Residual risk beyond confinement</span>'
            '</span>'
        )
    return ""


def write_html(summary, output_path):
    summary_rows = []
    detail_rows_by_key = {}

    for report in summary["reports"]:
        arch = html.escape(report["architecture"])
        actionable_pkgs = str(report["actionableAffectedPackages"])
        actionable_vulns = str(report["actionableVulnerabilities"])
        raw_matches = str(report["vulnerabilities"])
        confined_mitigations = str(report["confinedMitigationVulnerabilities"])
        report_time = (
            f'<time datetime="{html.escape(report["generatedAt"]["datetime"])}">'
            f'{html.escape(report["generatedAt"]["label"])}</time>'
        )
        report_link = f'<a class="p-button" href="{html.escape(report["report"])}" download>Download OSV</a>'
        
        report_cell = f'{report_time}<br><div style="margin-top: 0.5rem;">{report_link}</div>'
        
        summary_rows.append(
            f"<tr>"
            f"<td><strong>{arch}</strong></td>"
            f"<td>{actionable_pkgs}</td>"
            f"<td>{actionable_vulns}</td>"
            f"<td>{raw_matches}</td>"
            f"<td>{confined_mitigations}</td>"
            f"<td>{report_cell}</td>"
            f"</tr>"
        )

        for package in report["packages"]:
            for vulnerability in package["vulnerabilities"]:
                vuln_id_text = display_vulnerability_id(vulnerability["id"])
                vuln_id = html.escape(vuln_id_text)
                if vulnerability["url"]:
                    vuln_cell = (
                        f"<a href=\"{html.escape(vulnerability['url'])}\">{vuln_id}</a>"
                    )
                else:
                    vuln_cell = vuln_id

                publication_iso, publication_label = format_publication_date(
                    vulnerability.get("published") or vulnerability.get("modified")
                )
                detail_key = (
                    package["name"],
                    package["version"],
                    vuln_id_text,
                    vulnerability["url"],
                    vulnerability["severity"],
                    vulnerability["priority"],
                    vulnerability["patchable"],
                    publication_iso,
                    publication_label,
                    vulnerability.get("appropriate", ""),
                    vulnerability.get("not_appropriate", ""),
                )
                if detail_key not in detail_rows_by_key:
                    detail_rows_by_key[detail_key] = {
                        "package_name": package["name"],
                        "package_version": package["version"],
                        "vulnerability_cell": vuln_cell,
                        "vulnerability_id": vuln_id_text,
                        "severity": vulnerability["severity"],
                        "priority": vulnerability["priority"],
                        "patchable": vulnerability["patchable"],
                        "publication_iso": publication_iso,
                        "publication_label": publication_label,
                        "appropriate": vulnerability.get("appropriate", ""),
                        "not_appropriate": vulnerability.get("not_appropriate", ""),
                        "architectures": set(),
                    }
                detail_rows_by_key[detail_key]["architectures"].add(report["architecture"])

    detail_rows = []
    architecture_order = {"AMD64": 0, "ARM64": 1}
    for row_data in detail_rows_by_key.values():
        architecture_labels = sorted(
            {normalize_architecture_label(arch) for arch in row_data["architectures"]},
            key=lambda label: (architecture_order.get(label, 99), label),
        )
        architecture_cells = " ".join(
            architecture_chip(architecture) for architecture in architecture_labels
        )
        publication_label = row_data["publication_label"]
        publication_cell = html.escape(publication_label)
        if row_data["publication_iso"]:
            publication_cell = (
                f'<time datetime="{html.escape(row_data["publication_iso"])}">'
                f"{html.escape(publication_label)}</time>"
            )

        appropriate_text = (row_data.get("appropriate") or "").strip()
        not_appropriate_text = (row_data.get("not_appropriate") or "").strip()
        recommendation = confinement_recommendation(appropriate_text, not_appropriate_text)
        recommendation_label = CONFINEMENT_RECOMMENDATION_LABELS.get(recommendation, "")
        row_search = " ".join(
            [
                row_data["package_name"],
                row_data["package_version"],
                row_data["vulnerability_id"],
                row_data["severity"],
                row_data["priority"],
                "actionable" if row_data["patchable"] else "unactionable confined mitigation",
                publication_label,
                " ".join(architecture_labels),
                appropriate_text,
                not_appropriate_text,
                recommendation_label,
            ]
        ).lower()
        recommendation_html = ""
        if recommendation:
            recommendation_html = (
                f'<div style="margin-bottom: 0.75rem;">'
                f'{confinement_recommendation_badge(recommendation)}'
                f'</div>'
            )
        explanation_blocks = []
        if appropriate_text:
            explanation_blocks.append(
                f'<div style="flex: 1; min-width: 280px; border-left: 4px solid #1976d2; padding-left: 1rem;">'
                f'<h4 style="font-size: 0.9rem; font-weight: 600; color: #1976d2; margin-bottom: 0.25rem; text-transform: uppercase; letter-spacing: 0.5px;">Snap confinement mitigates risk</h4>'
                f'<p style="font-size: 0.875rem; line-height: 1.5; color: #333; margin: 0;">{html.escape(appropriate_text)}</p>'
                f'</div>'
            )
        if not_appropriate_text:
            explanation_blocks.append(
                f'<div style="flex: 1; min-width: 280px; border-left: 4px solid #d32f2f; padding-left: 1rem;">'
                f'<h4 style="font-size: 0.9rem; font-weight: 600; color: #d32f2f; margin-bottom: 0.25rem; text-transform: uppercase; letter-spacing: 0.5px;">Risk boundary extends beyond snap confinement</h4>'
                f'<p style="font-size: 0.875rem; line-height: 1.5; color: #333; margin: 0;">{html.escape(not_appropriate_text)}</p>'
                f'</div>'
            )

        detail_row_html = (
            f'<tr class="vulnerability-row" data-search="{html.escape(row_search)}">'
            f"<td>{html.escape(row_data['package_name'])}</td>"
            f"<td>{html.escape(row_data['package_version'])}</td>"
            f"<td>{row_data['vulnerability_cell']}</td>"
            f"<td>{severity_icon(row_data['severity'])}</td>"
            f"<td>{priority_icon(row_data['priority'])}</td>"
            f"<td>{status_badge(row_data['patchable'])}</td>"
            f"<td>{publication_cell}</td>"
            f"<td>{architecture_cells}</td>"
            "</tr>\n"
        )
        if explanation_blocks:
            detail_row_html += (
                f'<tr class="vulnerability-explanation-row" style="background-color: #fafafa;">'
                f'<td colspan="8" style="padding: 1rem 1.5rem !important; border-bottom: 1px solid #e0e0e0;">'
                f'{recommendation_html}'
                f'<div style="display: flex; gap: 2rem; flex-wrap: wrap;">'
                f'{"".join(explanation_blocks)}'
                f'</div>'
                f'</td>'
                f'</tr>'
            )
        detail_rows.append(detail_row_html)

    summary_table_rows = "\n".join(summary_rows) or (
        '<tr><td colspan="5">No OSV reports were generated.</td></tr>'
    )
    detail_body_rows = "\n".join(detail_rows) or (
        '<tr><td colspan="8">No unpatched vulnerabilities reported by OSV-Scanner.</td></tr>'
    )
    output_path.write_text(f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Vulnerability Reports - snap Pi-hole</title>
{vanilla_framework_css_link()}
    <style>
    .p-breadcrumbs {{
      min-height: 1.5rem;
    }}
    .p-breadcrumbs__item,
    .p-breadcrumbs__item a {{
      font-weight: 400;
      letter-spacing: normal;
      text-transform: none;
    }}
    .p-card__title,
    .p-heading--4 {{
      font-weight: 400;
    }}
    .vulnerability-summary-card-column {{
      display: flex;
    }}
    .vulnerability-summary-card {{
      display: flex;
      flex-direction: column;
      width: 100%;
    }}
    .vulnerability-summary-card .p-card__content {{
      margin-top: auto;
    }}
    .vulnerability-table-controls {{
      margin-bottom: 1.5rem;
    }}
    .vulnerability-sort-button {{
      background: none;
      border: 0;
      color: inherit;
      cursor: pointer;
      font: inherit;
      font-weight: 400;
      margin: 0;
      padding: 0;
      text-align: left;
    }}
    .vulnerability-sort-button::after {{
      content: "↕";
      display: inline-block;
      font-size: 0.8rem;
      margin-left: 0.35rem;
      color: #777;
    }}
    .vulnerability-sort-button[aria-sort="ascending"]::after {{
      content: "↑";
    }}
    .vulnerability-sort-button[aria-sort="descending"]::after {{
      content: "↓";
    }}
    .vulnerability-details {{
      table-layout: fixed;
      width: 100%;
    }}
    .vulnerability-details th,
    .vulnerability-details td {{
      line-height: 1.45;
      padding-bottom: 1rem !important;
      padding-top: 1rem !important;
      vertical-align: top;
    }}
    .vulnerability-details th:nth-child(1),
    .vulnerability-details td:nth-child(1) {{
      width: 14%;
    }}
    .vulnerability-details th:nth-child(2),
    .vulnerability-details td:nth-child(2) {{
      width: 12%;
    }}
    .vulnerability-details th:nth-child(3),
    .vulnerability-details td:nth-child(3) {{
      width: 14%;
    }}
    .vulnerability-details th:nth-child(4),
    .vulnerability-details td:nth-child(4) {{
      width: 11%;
    }}
    .vulnerability-details th:nth-child(5),
    .vulnerability-details td:nth-child(5) {{
      width: 10%;
    }}
    .vulnerability-details th:nth-child(6),
    .vulnerability-details td:nth-child(6) {{
      width: 15%;
    }}
    .vulnerability-details th:nth-child(7),
    .vulnerability-details td:nth-child(7) {{
      width: 12%;
    }}
    .vulnerability-details th:nth-child(8),
    .vulnerability-details td:nth-child(8) {{
      width: 12%;
    }}
    .vulnerability-details td:nth-child(2),
    .vulnerability-details td:nth-child(3) {{
      font-family: "Ubuntu Mono", monospace;
    }}
    .vulnerability-severity {{
      font-size: 12px;
      margin-bottom: 0;
      white-space: nowrap;
    }}
    .vulnerability-severity .p-chip__value {{
      font-size: 12px;
      font-weight: 400;
    }}
    .vulnerability-architecture {{
      margin-bottom: 0;
      margin-right: 0.3rem;
      white-space: nowrap;
    }}
    .vulnerability-architecture .p-chip__value {{
      font-size: 12px;
      font-weight: 400;
    }}
    footer.p-strip--dark {{
      background-color: #2d2d2d !important;
      color: #b6b6b6 !important;
    }}
    footer.p-strip--dark h2 {{
      color: #eaeaea !important;
      font-weight: 500 !important;
    }}
    footer.p-strip--dark p,
    footer.p-strip--dark li,
    footer.p-strip--dark span {{
      color: #b6b6b6 !important;
    }}
    footer.p-strip--dark a,
    footer.p-strip--dark a.is-dark {{
      color: rgb(102, 153, 204) !important;
      text-decoration: none !important;
      transition: color 0.15s ease !important;
    }}
    footer.p-strip--dark a:hover,
    footer.p-strip--dark a.is-dark:hover {{
      color: #e95420 !important;
      text-decoration: underline !important;
    }}
  </style>
</head>
<body>
  <div class="l-site">
    <header id="navigation" class="p-navigation is-dark">
      <div class="p-navigation__row">
        <div class="p-navigation__banner">
          <a class="p-navigation__link" href="../" style="display: flex; align-items: center; text-decoration: none;">
            <img src="../pihole.png" alt="Pi-hole Logo" style="height: 32px; width: 32px;">
          </a>
        </div>
      </div>
    </header>

    <main class="p-strip" style="background-color: #ffffff; flex-grow: 1; padding-top: 2rem !important; padding-bottom: 2rem !important;">
      <div class="row">
        <div class="col-12">
          <nav class="p-breadcrumbs" aria-label="Breadcrumbs" style="margin-bottom: 1.5rem;">
            <ol class="p-breadcrumbs__items">
              <li class="p-breadcrumbs__item"><a href="../">Reports Dashboard</a></li>
              <li class="p-breadcrumbs__item" aria-current="page">Vulnerability Reports</li>
            </ol>
          </nav>
          <section class="row" style="margin-bottom: 1rem;" aria-labelledby="vulnerability-title">
            <div class="col-12">
              <h1 class="p-heading--2" id="vulnerability-title" style="margin-bottom: 1.5rem;">Vulnerability Reports</h1>
              <p class="p-heading--4">OSV-Scanner findings from the generated SBOMs.</p>
            </div>
          </section>
          
          <div class="p-strip" style="background-color: #f7f7f7; padding: 1.5rem; border-radius: 4px; margin-bottom: 2rem; border-left: 4px solid #772953;">
            <h3 class="p-heading--4" style="margin-bottom: 0.5rem; color: #772953; font-weight: 500;">The value of snap confinement</h3>
            <p style="line-height: 1.6; margin-bottom: 1.25rem;">
              This report contains both <strong>Actionable</strong> (USN available) and <strong>Confined Mitigation</strong> (no USN or official patch available upstream) findings.
            </p>
            <p style="line-height: 1.6; margin-bottom: 0;">
              The CI workflow publishes OSV reports for visibility and fails only when the scanner itself errors. Known-vulnerability exit code 1 is treated as a warning. Unlike conventional deployments, a strictly confined snap executes within a sandbox: process capabilities and host interactions are restricted by <strong>AppArmor profiles, seccomp filters, and a read-only SquashFS filesystem</strong>.
            </p>
          </div>

          <h2 class="p-heading--3">Vulnerability Summary</h2>
          <div style="overflow-x: auto; margin-bottom: 0.5rem;">
            <table class="p-table" id="vulnerability-summary-table">
              <thead>
                <tr>
                  <th>Architecture</th>
                  <th>Actionable USN Packages</th>
                  <th>Actionable USN Vulnerabilities</th>
                  <th>Raw OSV Matches</th>
                  <th>Confined Mitigations</th>
                  <th>Report</th>
                </tr>
              </thead>
              <tbody>
                {summary_table_rows}
              </tbody>
            </table>
          </div>
          <p class="p-text--small" style="margin-bottom: 2rem;">
            Actionable counts include only vulnerability matches with a corresponding Ubuntu Security Notice (USN). Confined mitigations represent report-only matches that are sandboxed by snap confinement.
          </p>
          <h2 class="p-heading--3">Vulnerability Details</h2>
          <div class="row vulnerability-table-controls">
            <div class="col-12">
              <form class="p-search-box" onsubmit="event.preventDefault(); filterVulnerabilities();" style="margin-bottom: 0;">
                <label class="u-off-screen" for="vulnerability-search">Search by package, version, vulnerability, CVSS 3, priority, status, publication date, or architecture</label>
                <input type="search" id="vulnerability-search" class="p-search-box__input" placeholder="Search by package, version, vulnerability, CVSS 3, priority, status, publication date, architecture, or confinement analysis..." oninput="filterVulnerabilities()" autocomplete="off">
                <button type="reset" class="p-search-box__reset" onclick="document.getElementById('vulnerability-search').value=''; filterVulnerabilities();"><i class="p-icon--close">Clear</i></button>
                <button type="submit" class="p-search-box__button"><i class="p-icon--search">Search</i></button>
              </form>
            </div>
          </div>
          <div style="overflow-x: auto;">
            <table class="p-table vulnerability-details" id="vulnerability-table">
              <caption class="u-off-screen">OSV vulnerability details by package</caption>
              <thead>
                <tr>
                  <th><button type="button" class="vulnerability-sort-button" data-column="0" aria-sort="none" onclick="sortVulnerabilities(0)">Package</button></th>
                  <th><button type="button" class="vulnerability-sort-button" data-column="1" aria-sort="none" onclick="sortVulnerabilities(1)">Version</button></th>
                  <th><button type="button" class="vulnerability-sort-button" data-column="2" aria-sort="none" onclick="sortVulnerabilities(2)">Vulnerability</button></th>
                  <th><button type="button" class="vulnerability-sort-button" data-column="3" aria-sort="none" onclick="sortVulnerabilities(3)">CVSS 3</button></th>
                  <th><button type="button" class="vulnerability-sort-button" data-column="4" aria-sort="none" onclick="sortVulnerabilities(4)">Priority</button></th>
                  <th><button type="button" class="vulnerability-sort-button" data-column="5" aria-sort="none" onclick="sortVulnerabilities(5)">Status</button></th>
                  <th><button type="button" class="vulnerability-sort-button" data-column="6" aria-sort="none" onclick="sortVulnerabilities(6)">Publication Date</button></th>
                  <th><button type="button" class="vulnerability-sort-button" data-column="7" aria-sort="none" onclick="sortVulnerabilities(7)">Architectures</button></th>
                </tr>
              </thead>
              <tbody id="vulnerability-tbody">
                {detail_body_rows}
              </tbody>
            </table>
          </div>
          <p class="p-text--small">Full OSV JSON reports are linked in the summary table.</p>
        </div>
      </div>
    </main>

    <footer class="p-strip--dark" style="padding-top: 2rem !important; padding-bottom: 2rem !important; margin-top: 3rem;">
      <div class="row">
        <div class="col-4">
          <h2 class="p-heading--5">Project Resources</h2>
          <ul class="p-list">
            <li><a href="https://github.com/rajannpatel/snap-pi-hole" class="is-dark">GitHub Repository</a></li>
            <li><a href="https://github.com/rajannpatel/snap-pi-hole/wiki" class="is-dark">Project Wiki Documentation</a></li>
            <li><a href="https://snapcraft.io/pihole-by-rajannpatel" class="is-dark">Snap Store listing</a></li>
          </ul>
        </div>
        <div class="col-4">
          <h2 class="p-heading--5">CI/CD Pipeline</h2>
          <ul class="p-list">
            <li><a href="https://github.com/rajannpatel/snap-pi-hole/actions" class="is-dark">Workflow Execution History</a></li>
            <li><a href="https://github.com/rajannpatel/snap-pi-hole/actions/workflows/cicd.yml" class="is-dark">Pipeline Definition (YAML)</a></li>
            <li><a href="../sbom/" class="is-dark">Software Bill of Materials (SBOM)</a></li>
            <li><a href="../vulnerabilities/" class="is-dark">Vulnerability Reports</a></li>
            <li><a href="../coverage/" class="is-dark">Code Coverage Reports</a></li>
          </ul>
        </div>
        <div class="col-4">
          <h2 class="p-heading--5">Security & Confinement</h2>
          <p class="p-text--small">
            Built securely on Ubuntu builders. Packaged as a strictly confined snap, ensuring isolated execution and sandboxed system interactions for Pi-hole Core services.
          </p>
        </div>
      </div>
    </footer>
  </div>
  <script>
    let vulnerabilitySortColumn = null;
    let vulnerabilitySortDirection = 'ascending';

    function vulnerabilityCellValue(row, column) {{
      const cell = row.cells[column];
      return cell ? cell.textContent.trim().toLowerCase() : '';
    }}

    function vulnerabilityCvssScore(value) {{
      const match = value.match(/\\d+(?:\\.\\d+)?/);
      return match ? Number(match[0]) : null;
    }}

    function vulnerabilityPriorityRank(value) {{
      const normalized = value.toLowerCase();
      if (normalized.includes('critical')) return 5;
      if (normalized.includes('high')) return 4;
      if (normalized.includes('medium')) return 3;
      if (normalized.includes('low')) return 2;
      if (normalized.includes('negligible')) return 1;
      if (normalized.includes('unknown')) return null;
      return null;
    }}

    function vulnerabilityRankValue(row, column) {{
      const value = vulnerabilityCellValue(row, column);
      if (column === 3) {{
        return vulnerabilityCvssScore(value);
      }}
      if (column === 4) {{
        return vulnerabilityPriorityRank(value);
      }}
      return null;
    }}

    function compareVulnerabilityRows(firstRow, secondRow, column, direction) {{
      const firstRank = vulnerabilityRankValue(firstRow, column);
      const secondRank = vulnerabilityRankValue(secondRow, column);
      if (firstRank !== null || secondRank !== null || column === 3 || column === 4) {{
        if (firstRank === null && secondRank === null) {{
          const firstText = vulnerabilityCellValue(firstRow, column);
          const secondText = vulnerabilityCellValue(secondRow, column);
          return firstText.localeCompare(secondText, undefined, {{ numeric: true, sensitivity: 'base' }});
        }}
        if (firstRank === null) {{
          return 1;
        }}
        if (secondRank === null) {{
          return -1;
        }}
        return direction === 'ascending' ? firstRank - secondRank : secondRank - firstRank;
      }}

      const firstText = vulnerabilityCellValue(firstRow, column);
      const secondText = vulnerabilityCellValue(secondRow, column);
      const lexical = firstText.localeCompare(secondText, undefined, {{ numeric: true, sensitivity: 'base' }});
      return direction === 'ascending' ? lexical : -lexical;
    }}

    function defaultSortDirection(column) {{
      if (column === 3 || column === 4) {{
        return 'descending';
      }}
      return 'ascending';
    }}

    function filterVulnerabilities() {{
      const searchInput = document.getElementById('vulnerability-search');
      const query = searchInput ? searchInput.value.toLowerCase().trim() : '';
      const rows = document.querySelectorAll('#vulnerability-tbody tr.vulnerability-row');
      rows.forEach(row => {{
        const nextRow = row.nextElementSibling;
        const searchText = row.dataset.search || row.textContent.toLowerCase();
        const matches = !query || searchText.includes(query);
        const displayStyle = matches ? '' : 'none';
        row.style.display = displayStyle;
        if (nextRow && nextRow.classList.contains('vulnerability-explanation-row')) {{
          nextRow.style.display = displayStyle;
        }}
      }});
    }}

    function sortVulnerabilities(column) {{
      const tbody = document.getElementById('vulnerability-tbody');
      const parentRows = Array.from(tbody.querySelectorAll('tr.vulnerability-row'));
      if (vulnerabilitySortColumn === column) {{
        vulnerabilitySortDirection = vulnerabilitySortDirection === 'ascending' ? 'descending' : 'ascending';
      }} else {{
        vulnerabilitySortColumn = column;
        vulnerabilitySortDirection = defaultSortDirection(column);
      }}

      const pairs = parentRows.map(row => {{
        return {{
          parent: row,
          explanation: row.nextElementSibling && row.nextElementSibling.classList.contains('vulnerability-explanation-row') ? row.nextElementSibling : null
        }};
      }});

      pairs.sort((a, b) => compareVulnerabilityRows(a.parent, b.parent, column, vulnerabilitySortDirection));

      pairs.forEach(pair => {{
        tbody.appendChild(pair.parent);
        if (pair.explanation) {{
          tbody.appendChild(pair.explanation);
        }}
      }});

      document.querySelectorAll('.vulnerability-sort-button').forEach(button => {{
        const isActive = Number(button.dataset.column) === column;
        button.setAttribute('aria-sort', isActive ? vulnerabilitySortDirection : 'none');
      }});
      filterVulnerabilities();
    }}
  </script>
</body>
</html>
""", encoding="utf-8")


def main():
    reports_dir = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "vulnerability-reports")
    reports_dir.mkdir(parents=True, exist_ok=True)
    summary = collect_reports(reports_dir)
    (reports_dir / "osv-summary.json").write_text(
        json.dumps(summary, indent=2) + "\n",
        encoding="utf-8",
    )
    write_markdown(summary, reports_dir / "vuln-summary.md")
    write_html(summary, reports_dir / "index.html")


if __name__ == "__main__":
    main()
