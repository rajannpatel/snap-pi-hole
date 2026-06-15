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
import uuid
from datetime import datetime, timezone

from report_assets import vanilla_framework_css_link
from llm_model import select_best_model, select_candidate_models, DEFAULT_MODEL, init_providers


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
PROMPT_CONFINEMENT_PLACEHOLDER = "{{CONFINEMENT_CAPABILITIES}}"

# Read so the model audits against the real build toolchain and packaging
# instead of guessing. The snap is assembled in public GitHub Actions, so these
# facts are verifiable rather than assumed.
SNAPCRAFT_YAML_PATH = (
    pathlib.Path(__file__).resolve().parent.parent.parent / "snapcraft.yaml"
)

# The snap's own additions that actually ship and run inside the deployed snap:
# the patches applied to upstream sources (including the FTL C patches), the snapd
# hooks, and the runtime wrapper scripts. These are where this project introduces
# attack surface the upstream Pi-hole audit knowledge does not cover (for example
# piping the GitHub release API response through `jq`). Build- and test-only trees
# are deliberately excluded: attacker-influenced input never reaches them.
SNAP_DIR = SNAPCRAFT_YAML_PATH.parent
REPO_ROOT_DIR = SNAP_DIR.parent
SNAP_RUNTIME_SOURCE_DIRS = (
    SNAP_DIR / "local" / "patches",
    SNAP_DIR / "hooks",
    SNAP_DIR / "local" / "runtime",
)
MAX_SNAP_INVOCATION_SITES = 8

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

Confinement capabilities (the exact snapd interfaces this snap declares; strict confinement is not a uniform sandbox, so bound each finding's blast radius by the interfaces declared for the app the vulnerable code actually runs in. Interfaces marked * reach beyond the snap's own data to the host when connected; distinguish declared capability from proven active connection unless the input proves the plug is connected):
{{CONFINEMENT_CAPABILITIES}}

Each finding carries cve, package, version, details, and when available aliases, severity, a fix_available flag with fixed_versions, reference URLs, and a snap_invocations list of real `path:line: code` call sites grepped from the snap's own shipped patches, hooks, and runtime scripts; treat that as the source of truth. For each finding reason about the real attack vector, then whether the vulnerable code is reachable from the snap's services with attacker-influenced input — grounded in snap_invocations when present, and remembering that untrusted input can arrive indirectly. Use explicit reachability confidence: confirmed reachable only when evidence shows a relevant call path receiving untrusted or operator-supplied input; plausibly reachable when the affected code is shipped and linked into a network-facing component but the exact path is not proven; not evident from audited evidence when no path is visible. This audit does not enumerate the full upstream Pi-hole/FTL tree, so never assert that no code path passes attacker-influenced data to a component. Honor the finding's official impact fields and CVSS vector: if the advisory is availability-only (for example C:N/I:N/A:H), keep residual risk focused on service availability unless supplied evidence independently proves confidentiality loss, integrity impact, or arbitrary code execution. AppArmor/seccomp/read-only SquashFS block classic escapes (host filesystem writes, kernel modules, ptrace) so host takeover is normally out of reach. Host-reaching interfaces declared by pihole-FTL (network-control, firewall-control, process-control, time-control) are blast-radius context; mention abuse of them as residual risk only when the advisory or evidence supports code execution or integrity impact. A remotely triggerable crash of the running resolver, DNS cache poisoning, unbounded data growth, or supported interface abuse can be residual risk; compounding hypotheticals are not.

Return a single JSON object and nothing else: keys are the exact vulnerability identifiers (every id in the batch must appear as a key — never drop a finding, even one you judge contained or inapplicable), and each value is an object with either or both of two string keys. Always include "appropriate": a thorough, specific case for how snap confinement mitigates the risk, including attack vector, applicability, reachability confidence, official impact calibration, and how AppArmor/seccomp/read-only SquashFS cap the blast radius and block host compromise. Include "not_appropriate" only when a concrete, reachable, material residual risk genuinely remains and keep it aligned with official CVSS/vendor impact and supplied evidence. Do not claim host-control, firewall/network reconfiguration, confidentiality loss, integrity impact, or arbitrary code execution unless the advisory or project evidence supports it. Omit not_appropriate for speculative, hypothetical, negligible, or non-shipped-code risks, and never fill it with a no-risk disclaimer such as "No residual risk", "None", or "N/A" (its absence already signals containment). At least one key must be present per finding. Be specific and evidence-based; no filler, no Markdown, no text outside the JSON object.

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


# Curated security meaning of the snapd interfaces this snap plugs. The boolean
# marks interfaces whose grant extends a compromised process's blast radius
# BEYOND the snap's own writable data, to host or cross-process state.
_INTERFACE_IMPLICATIONS = {
    "network": ("make outbound network connections", False),
    "network-bind": ("listen on ports to act as a server (DNS 53, web 80/443)", False),
    "network-observe": ("read network configuration and status, read-only", False),
    "system-observe": ("read system and process state, read-only", False),
    "hardware-observe": ("read hardware information, read-only", False),
    "mount-observe": ("read the mount table, read-only", False),
    "shared-memory": ("use a private /dev/shm namespace", False),
    "network-control": (
        "reconfigure host network interfaces, routing, and namespaces", True),
    "firewall-control": ("modify the host firewall (iptables/nftables)", True),
    "process-control": ("signal and kill other processes", True),
    "time-control": ("set the system clock", True),
    "shutdown": ("shut down or reboot the host", True),
    "mount-control": ("create and remove mounts", True),
    "system-files": ("read or write declared host file paths", True),
}

# Committed fallback mirroring the snapcraft.yaml apps: block, so the capability
# provenance stays accurate even if the file moves or PyYAML is unavailable at
# runtime (the script never imports yaml at module load).
_DEFAULT_SNAPCRAFT_APPS = [
    {"name": "pihole-ftl", "role": "daemon", "plugs": [
        "network", "network-bind", "network-observe", "system-observe",
        "hardware-observe", "mount-observe", "network-control",
        "firewall-control", "process-control", "time-control", "shared-memory"]},
    {"name": "pihole", "role": "command", "plugs": [
        "network", "network-bind", "network-observe", "system-observe",
        "hardware-observe", "mount-observe"]},
    {"name": "snap-check", "role": "command", "plugs": [
        "network", "network-bind", "system-observe", "network-observe"]},
    {"name": "snap-setup", "role": "command", "plugs": [
        "network", "network-bind", "system-observe", "network-observe"]},
    {"name": "snap-debug", "role": "command", "plugs": [
        "network", "network-bind", "system-observe", "hardware-observe",
        "mount-observe"]},
    {"name": "sqlite3", "role": "command", "plugs": ["network", "network-bind"]},
    {"name": "gravity-sync", "role": "timer", "plugs": [
        "network", "network-bind", "network-observe", "system-observe",
        "hardware-observe", "mount-observe"]},
]

_ROLE_LABELS = {
    "daemon": "long-running daemon",
    "timer": "scheduled task",
    "command": "CLI/diagnostic command",
}


def _snapcraft_apps():
    """Parse the apps and their plugged interfaces from snapcraft.yaml.

    Uses PyYAML when available (imported lazily so the module never hard-depends
    on it) and degrades to the committed defaults otherwise, so the capability
    provenance is always populated.
    """
    try:
        import yaml

        data = yaml.safe_load(SNAPCRAFT_YAML_PATH.read_text(encoding="utf-8"))
        apps = (data or {}).get("apps") or {}
        parsed = []
        for name, spec in apps.items():
            spec = spec or {}
            role = "command"
            if spec.get("daemon"):
                role = "timer" if spec.get("timer") else "daemon"
            plugs = [p for p in (spec.get("plugs") or []) if isinstance(p, str)]
            parsed.append({"name": name, "role": role, "plugs": plugs})
        if parsed:
            return parsed
    except Exception:
        pass
    return [dict(app, plugs=list(app["plugs"])) for app in _DEFAULT_SNAPCRAFT_APPS]


def confinement_capability_block():
    """Render the snap's actual capability surface from its declared interfaces.

    The model must bound a finding's blast radius by the interfaces the affected
    app really holds, not by a generic assumption that strict confinement limits
    everything to the snap's own data. Interfaces that reach the host are called
    out explicitly with the apps that hold them.
    """
    apps = _snapcraft_apps()
    level = _snapcraft_build_facts().get("confinement", "strict")
    lines = [
        f"- Confinement: `{level}` confinement (AppArmor, seccomp, and a read-only "
        "SquashFS root). The interfaces below are exactly what this snap requests "
        "in snapcraft.yaml; a finding's real blast radius is bounded by the "
        "interfaces held by the app it actually runs in, not by an assumption that "
        "strict confinement caps everything at the snap's own data.",
        "- Component-to-app mapping: the compiled C daemon `pihole-FTL` runs as the "
        "app holding the broadest interface set, and libraries such as mbedTLS, "
        "nettle, libidn2, libuv, lmdb, and sqlite3 are linked into it \u2014 a "
        "memory-safety bug in any of them inherits that daemon's capabilities. "
        "Utilities such as jq run instead in the Pi-hole shell CLIs, the snapd "
        "hooks, and helper apps, which hold a narrower set.",
    ]
    host_reaching = {}
    unclassified = {}
    for app in apps:
        marked = []
        for plug in app["plugs"]:
            impl = _INTERFACE_IMPLICATIONS.get(plug)
            if impl is None:
                unclassified.setdefault(plug, set()).add(app["name"])
                marked.append(plug + "\u2020")
            elif impl[1]:
                host_reaching.setdefault(plug, set()).add(app["name"])
                marked.append(plug + "*")
            else:
                marked.append(plug)
        role = _ROLE_LABELS.get(app["role"], app["role"])
        lines.append(
            f"- App `{app['name']}` ({role}): {', '.join(marked) or 'no extra interfaces'}."
        )
    if host_reaching:
        lines.append(
            "- Interfaces marked * reach beyond the snap's own writable data and are "
            "real residual-risk amplifiers whenever the vulnerable code runs in an "
            "app that holds them:"
        )
        for plug in sorted(host_reaching):
            holders = ", ".join(sorted(host_reaching[plug]))
            lines.append(
                f"  - `{plug}` (held by {holders}): {_INTERFACE_IMPLICATIONS[plug][0]}."
            )
    if unclassified:
        joined = ", ".join(
            f"`{plug}` ({', '.join(sorted(apps))})"
            for plug, apps in sorted(unclassified.items())
        )
        lines.append(
            "- Interfaces marked \u2020 are not pre-classified here; do not assume "
            f"they are contained \u2014 reason about what each grants: {joined}."
        )
    lines.append(
        "- Writable state lives in the snap's own data directories ($SNAP_DATA, "
        "$SNAP_COMMON) on the host filesystem with no size quota, so a bug that "
        "drives unbounded query logging or database growth is a host "
        "disk-exhaustion availability risk, not merely an in-snap one."
    )
    return "\n".join(lines)


def _usage_tokens(package_name):
    """Derive grep tokens for a finding's component from its OSV package name.

    Takes the leading package name plus any parenthesised binary/applet (so
    "lmdb (mdb_load)" yields {lmdb, mdb_load} and "rust-coreutils (sort)" yields
    {rust-coreutils, sort}). Tokens of any length are kept — including a future
    single-character package name — provided they are plain identifiers; how each
    token is matched (see ``_compile_usage_pattern``) is what keeps short, generic
    names from misfiring, so length is not used to exclude them here.
    """
    raw = str(package_name or "")
    tokens = {re.split(r"[\s(]", raw, 1)[0].strip()}
    for inner in re.findall(r"\(([^)]*)\)", raw):
        for part in re.split(r"[,\s/]+", inner):
            tokens.add(part.strip())
    return {t for t in tokens if len(t) >= 1 and re.fullmatch(r"[A-Za-z0-9_.+-]+", t)}


def _compile_usage_pattern(token):
    """Compile the search pattern used to find a token's real invocation sites.

    A distinctive token (three characters or more) is specific enough that a plain
    word-boundary match is both safe and high-recall. Short tokens such as "jq",
    "su", "yq" — or a hypothetical one-character package name — are too generic for
    a bare word match, which would flag every stray letter in prose. For those,
    require the token to appear in true command position: at a statement start, in
    a pipeline, after a separator, command substitution, backtick, or an explicit
    command runner (sudo/exec/xargs/env/…), optionally via an absolute path, or as
    a C ``#include`` target. Shell ``${var}`` parameter and ``$((expr))`` arithmetic
    expansions are deliberately excluded so a package whose name collides with a
    shell variable is not misreported. This is what lets the length floor be
    removed without reintroducing false positives.
    """
    esc = re.escape(token)
    if len(token) >= 3:
        return re.compile(r"\b" + esc + r"\b")
    runners = r"exec|xargs|command|sudo|env|nohup|nice|timeout|time|watch"
    # A statement boundary, then optional leading VAR=value assignments and an
    # optional absolute-path prefix, immediately before the token.
    command = (
        r"(?:^|[|;&`]|\$\(|\b(?:" + runners + r")\s+(?:-\S+\s+)*)\s*"
        r"(?:[A-Za-z_]\w*=\S*\s+)*(?:[\w./-]*/)?"
    )
    include = r"#\s*include\s*[<\"]\s*(?:[\w./-]*/)*"
    return re.compile(r"(?:" + command + "|" + include + ")" + esc + r"(?![\w.+-])")


# C preprocessor directives begin with `#` but are code, not prose comments, so a
# matched `#include <pkg/...>` line is kept as real evidence the component is used.
_C_PREPROCESSOR_KEYWORDS = frozenset(
    {
        "include", "define", "undef", "if", "ifdef", "ifndef", "elif", "else",
        "endif", "pragma", "error", "warning", "line",
    }
)


def _is_prose_comment(text):
    """True when ``text`` is a human comment line rather than an invocation.

    Skipping these stops a passing mention of a package in a code comment (for
    example a note about AppArmor and rust-coreutils) from being reported as a
    real call site. C preprocessor directives are explicitly not comments.
    """
    if text.startswith(("//", "/*", "*")):
        return True
    if text.startswith("#"):
        first = re.split(r"[^A-Za-z]", text[1:].lstrip(), 1)[0].lower()
        return first not in _C_PREPROCESSOR_KEYWORDS
    return False


def _iter_snap_runtime_files():
    for root in SNAP_RUNTIME_SOURCE_DIRS:
        if not root.exists():
            continue
        for path in sorted(root.rglob("*")):
            if path.is_file():
                yield path


def snap_usage_sites(package_name, limit=MAX_SNAP_INVOCATION_SITES):
    """Find real invocation sites of a finding's component in the snap's own code.

    Searches only the code this project actually ships and runs inside the snap
    (applied patches, snapd hooks, runtime wrapper scripts) for the component's
    tokens, and returns verifiable ``relpath:line: code`` evidence the model can
    use to judge whether attacker-influenced data can reach the vulnerable code.

    For ``.patch`` files, lines the patch removes are skipped (they are not
    shipped) and the diff marker is stripped so the model sees the shipped code.
    Prose comment lines are skipped so a passing mention is not misreported as a
    call site. An empty list means no direct use was found in the snap's own
    additions; it does **not** prove the component is unreachable, because the
    staged upstream Pi-hole and FTL sources are not enumerated here.
    """
    tokens = _usage_tokens(package_name)
    if not tokens:
        return []
    patterns = [_compile_usage_pattern(t) for t in tokens]
    sites = []
    seen = set()
    for path in _iter_snap_runtime_files():
        is_patch = path.suffix == ".patch"
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for lineno, raw_line in enumerate(lines, 1):
            line = raw_line.strip()
            if not line or line.startswith("#!"):
                continue
            if line.startswith(("+++", "---", "@@", "diff ", "index ")):
                continue
            if is_patch and line.startswith("-"):
                continue  # removed by the patch, so not shipped
            code = line.lstrip("+").strip() if is_patch else line
            if _is_prose_comment(code):
                continue
            if not any(p.search(code) for p in patterns):
                continue
            try:
                rel = path.relative_to(REPO_ROOT_DIR)
            except ValueError:
                rel = path
            key = (str(rel), lineno)
            if key in seen:
                continue
            seen.add(key)
            sites.append(f"{rel}:{lineno}: {code[:200]}")
            if len(sites) >= limit:
                return sites
    return sites


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
    # Resolve the provenance placeholders up front so every consumer (prompt
    # assembly and batch-overhead estimation) sees the real build and capability
    # facts; only the per-batch CVE placeholder remains for the caller to fill.
    text = text.replace(
        PROMPT_BUILD_PROVENANCE_PLACEHOLDER, build_provenance_block()
    )
    text = text.replace(
        PROMPT_CONFINEMENT_PLACEHOLDER, confinement_capability_block()
    )
    return text


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
    # Verifiable, in-repo evidence of where this component is invoked by the
    # snap's own shipped code, so the model grounds reachability in real call
    # sites instead of guessing about upstream behaviour.
    invocations = snap_usage_sites(entry["package"])
    if invocations:
        entry["snap_invocations"] = invocations
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

    providers = init_providers()
    if not providers:
        print("No LLM providers configured. Using fallback placeholders for batch vulnerabilities.", file=sys.stderr)
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

    global _active_provider_idx
    if '_active_provider_idx' not in globals():
        globals()['_active_provider_idx'] = 0
    
    _active_provider_idx = _active_provider_idx % len(providers)

    batches = list(iter_vuln_batches(vulns_to_query))
    results = {}
    for index, batch in enumerate(batches):
        current_time = time.time()
        all_cooldown = True
        min_cooldown = None
        for p in providers:
            if p.cooldown_until <= current_time:
                all_cooldown = False
                break
            if min_cooldown is None or p.cooldown_until < min_cooldown:
                min_cooldown = p.cooldown_until
                
        if all_cooldown and min_cooldown is not None and (min_cooldown - current_time) > 600:
            print("All LLM providers are in absurd cooldown. Skipping all remaining query batches and using fallbacks.", file=sys.stderr)
            for remaining_batch in batches[index:]:
                for v in remaining_batch:
                    results[v["cve_id"]] = {
                        "appropriate": LLM_LOOKUP_ERROR_TEXT,
                        "not_appropriate": LLM_LOOKUP_ERROR_TEXT
                    }
            break

        if index > 0 and BATCH_PACING_SECONDS > 0:
            time.sleep(BATCH_PACING_SECONDS)
        if len(batches) > 1:
            print(
                f"Querying LLM batch {index + 1}/{len(batches)} ({len(batch)} vulnerabilities)...",
                file=sys.stderr,
            )
        results.update(_query_vuln_batch_once(batch, providers, model_override=model))

    if len(vulns_to_query) > 1:
        by_id = {v["cve_id"]: v for v in vulns_to_query}
        failed_ids = [
            cid for cid in by_id if is_failed_explanation(results.get(cid))
        ]
        
        current_time = time.time()
        all_cooldown = True
        min_cooldown = None
        for p in providers:
            if p.cooldown_until <= current_time:
                all_cooldown = False
                break
            if min_cooldown is None or p.cooldown_until < min_cooldown:
                min_cooldown = p.cooldown_until
                
        if not (all_cooldown and min_cooldown is not None and (min_cooldown - current_time) > 600):
            for cid in failed_ids:
                if BATCH_PACING_SECONDS > 0:
                    time.sleep(BATCH_PACING_SECONDS)
                
                # Check again before each individual query in case it just hit absurd cooldown
                current_time = time.time()
                all_cooldown = True
                min_cooldown = None
                for p in providers:
                    if p.cooldown_until <= current_time:
                        all_cooldown = False
                        break
                    if min_cooldown is None or p.cooldown_until < min_cooldown:
                        min_cooldown = p.cooldown_until
                if all_cooldown and min_cooldown is not None and (min_cooldown - current_time) > 600:
                    print("All LLM providers entered absurd cooldown. Skipping individual re-queries.", file=sys.stderr)
                    break

                print(
                    f"Re-querying {cid} individually after a batch miss...",
                    file=sys.stderr,
                )
                providers = init_providers()
                _active_provider_idx = _active_provider_idx % len(providers)
                salvaged = _query_vuln_batch_once([by_id[cid]], providers, model_override=model)
                if not is_failed_explanation(salvaged.get(cid)):
                    results[cid] = salvaged[cid]
    return results


def _query_vuln_batch_once(vulns_to_query, providers, model_override=None):
    global _active_provider_idx
    max_attempts = max(1, int(os.environ.get("LLM_MAX_ATTEMPTS") or "3"))
    retry_base_delay = max(0.0, float(os.environ.get("LLM_RETRY_BASE_DELAY_SECONDS") or "2.0"))

    prompt = build_analysis_prompt(vulns_to_query)

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

    max_total_tries = max_attempts * len(providers)
    attempt = 0
    provider_models = {p.name: list(p.models) for p in providers}

    while attempt < max_total_tries:
        attempt += 1
        _active_provider_idx = _active_provider_idx % len(providers)
        provider = providers[_active_provider_idx]
        
        current_time = time.time()
        if provider.cooldown_until > current_time:
            if len(providers) > 1:
                other_idx = (_active_provider_idx + 1) % len(providers)
                other_provider = providers[other_idx]
                if other_provider.cooldown_until <= current_time:
                    _active_provider_idx = other_idx
                    provider = other_provider
                else:
                    sleep_time = min(provider.cooldown_until, other_provider.cooldown_until) - current_time
                    if sleep_time > 600:
                        print(f"All providers in cooldown with minimum wait {sleep_time:.2f}s > 600s (absurd). Aborting LLM query and returning cache/fallbacks.", file=sys.stderr)
                        break
                    print(f"All providers in cooldown. Waiting for {sleep_time:.2f}s...", file=sys.stderr)
                    time.sleep(max(0.1, sleep_time))
                    current_time = time.time()
            else:
                sleep_time = provider.cooldown_until - current_time
                if sleep_time > 600:
                    print(f"Provider {provider.name} in cooldown with wait {sleep_time:.2f}s > 600s (absurd). Aborting LLM query and returning cache/fallbacks.", file=sys.stderr)
                    break
                print(f"Provider {provider.name} in cooldown. Waiting for {sleep_time:.2f}s...", file=sys.stderr)
                time.sleep(max(0.1, sleep_time))
                current_time = time.time()

        if not provider.discovered:
            if model_override:
                if isinstance(model_override, str):
                    provider.models = [model_override]
                else:
                    provider.models = list(model_override)
            else:
                try:
                    provider.models = select_candidate_models(provider.api_key, provider.base_url)
                except Exception as exc:
                    print(f"Model discovery failed for {provider.name} ({exc}); using default model {provider.default_model}.", file=sys.stderr)
                    provider.models = [provider.default_model]
            provider.discovered = True
            provider_models[provider.name] = list(provider.models)

        models_list = provider_models.get(provider.name) or [provider.default_model]
        if not models_list:
            models_list = list(provider.models)
            provider_models[provider.name] = models_list
        model = models_list[0]

        body = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "response_format": {"type": "json_object"},
            "max_tokens": max(256, int(os.environ.get("LLM_MAX_OUTPUT_TOKENS") or "4000")),
        }
        
        url = f"{provider.base_url.rstrip('/')}/chat/completions"
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {provider.api_key}",
        }

        try:
            req = urllib.request.Request(
                url,
                data=json.dumps(body).encode("utf-8"),
                headers=headers,
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=90) as response:
                resp_data = json.loads(response.read().decode("utf-8"))
                return parse_llm_response(resp_data)
        except urllib.error.HTTPError as exc:
            response_body = ""
            try:
                response_body = exc.read().decode("utf-8", errors="replace").strip()
            except Exception:
                pass
            print(
                f"{provider.name} LLM API HTTP error for batch query (model: {model}, attempt {attempt}/{max_total_tries}): status {exc.code}. "
                f"Response body: {response_body or '<empty>'}",
                file=sys.stderr,
            )
            
            if exc.code == 429:
                sleep_delay = None
                resp_headers = exc.headers or {}
                retry_after = resp_headers.get("Retry-After")
                if retry_after:
                    try:
                        sleep_delay = max(2.0, float(retry_after) + 0.5)
                        print(f"Rate limit detected. Retry-After header: sleep {sleep_delay:.2f}s.", file=sys.stderr)
                    except ValueError:
                        pass
                if sleep_delay is None:
                    reset_time = resp_headers.get("x-ratelimit-reset") or resp_headers.get("X-RateLimit-Reset")
                    if reset_time:
                        try:
                            sleep_delay = max(2.0, float(reset_time) - time.time() + 1.0)
                            print(f"Rate limit detected. x-ratelimit-reset header: sleep {sleep_delay:.2f}s.", file=sys.stderr)
                        except ValueError:
                            pass
                if sleep_delay is None and response_body:
                    match = re.search(r"(?:retry in|try again in|retry after) (\d+\.?\d*)(?:\s*s|\s*second)", response_body, re.IGNORECASE)
                    if match:
                        try:
                            sleep_delay = max(2.0, float(match.group(1)) + 0.5)
                            print(f"Rate limit detected. Response body: sleep {sleep_delay:.2f}s.", file=sys.stderr)
                        except ValueError:
                            pass

                # Check for daily/permanent quota exhaustion
                if response_body and ("quota exceeded" in response_body.lower() or "exceeded your current quota" in response_body.lower()):
                    sleep_delay = 86400.0  # 1 day
                    print(f"{provider.name} daily/monthly quota exhausted. Setting 24h cooldown.", file=sys.stderr)

                if sleep_delay is None:
                    sleep_delay = max(2.0, min(retry_base_delay * (2 ** (attempt - 1)), 30.0))

                provider.cooldown_until = time.time() + sleep_delay

                # Find if any provider is ready (not in cooldown)
                current_time = time.time()
                ready_provider = None
                for p in providers:
                    if p.cooldown_until <= current_time:
                        ready_provider = p
                        break

                if ready_provider:
                    print(f"Rate limit hit on {provider.name}. Alternating to ready provider {ready_provider.name} immediately.", file=sys.stderr)
                    _active_provider_idx = providers.index(ready_provider)
                    continue

                # If no provider is ready, calculate wait time
                sleep_time = min(p.cooldown_until for p in providers) - current_time
                if sleep_time > 600:
                    print(f"All providers in cooldown with minimum wait {sleep_time:.2f}s > 600s (absurd). Aborting LLM query and returning cache/fallbacks.", file=sys.stderr)
                    break

                # Sleep for the minimum wait time, then run again with the provider that becomes ready
                next_ready_provider = min(providers, key=lambda p: p.cooldown_until)
                print(f"All providers in cooldown. Sleeping for {sleep_time:.2f}s to wait for {next_ready_provider.name}...", file=sys.stderr)
                time.sleep(max(0.1, sleep_time))
                _active_provider_idx = providers.index(next_ready_provider)
                continue
            
            elif exc.code in {500, 502, 503, 504}:
                if len(providers) > 1:
                    print(f"{provider.name} server error (HTTP {exc.code}). Alternating provider...", file=sys.stderr)
                    _active_provider_idx = (_active_provider_idx + 1) % len(providers)
                    continue
                else:
                    time.sleep(min(retry_base_delay * (2 ** (attempt - 1)), 8.0))
                    continue
            else:
                if len(models_list) > 1:
                    print(f"Model {model} failed with HTTP {exc.code}. Rotating model...", file=sys.stderr)
                    models_list.pop(0)
                    continue
                if len(providers) > 1:
                    print(f"{provider.name} failed with HTTP {exc.code}. Alternating provider...", file=sys.stderr)
                    _active_provider_idx = (_active_provider_idx + 1) % len(providers)
                    continue
                break
                
        except (urllib.error.URLError, TimeoutError) as exc:
            print(f"{provider.name} API connection or timeout error for batch query (model: {model}): {exc}.", file=sys.stderr)
            if len(providers) > 1:
                print("Alternating provider due to connection error...", file=sys.stderr)
                _active_provider_idx = (_active_provider_idx + 1) % len(providers)
                continue
            else:
                time.sleep(min(retry_base_delay * (2 ** (attempt - 1)), 8.0))
                continue
                
        except (json.JSONDecodeError, KeyError, IndexError, ValueError) as exc:
            print(f"{provider.name} API response parsing error for batch query (model: {model}): {exc}.", file=sys.stderr)
            if len(models_list) > 1:
                print("Rotating model due to parsing error...", file=sys.stderr)
                models_list.pop(0)
                continue
            if len(providers) > 1:
                print("Alternating provider due to parsing error...", file=sys.stderr)
                _active_provider_idx = (_active_provider_idx + 1) % len(providers)
                continue
            break
            
        except Exception as exc:
            print(f"Unexpected LLM lookup error for batch query (model: {model}): {type(exc).__name__}: {exc}.", file=sys.stderr)
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
        'class="vulnerability-severity-icon">'
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
    parts = str(architecture).strip().lower().split("-")
    arch = parts[1] if len(parts) == 2 else parts[0]
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


def channel_chip(channel):
    return (
        '<span class="p-chip vulnerability-channel">'
        f'<span class="p-chip__value">{html.escape(str(channel).strip().lower())}</span>'
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
    runtime_explanations = {}
    has_llm = len(init_providers()) > 0

    uncached_vulns_to_query = []
    seen_uncached = set()
    vuln_id_to_modified = {}
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
                    if not vuln_id:
                        continue
                    report_modified = v.get("modified", "")
                    cached = cache.get(vuln_id)
                    
                    needs_query = False
                    if cached is None or is_failed_explanation(cached):
                        needs_query = True
                    elif report_modified:
                        cached_modified = cached.get("modified", "")
                        if cached_modified and cached_modified != report_modified:
                            needs_query = True
                        elif not cached_modified:
                            cached["modified"] = report_modified
                            cache_updated = True

                    if needs_query and vuln_id not in seen_uncached:
                        vuln_id_to_modified[vuln_id] = report_modified
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

    if uncached_vulns_to_query:
        print(f"Querying LLM in batch for {len(uncached_vulns_to_query)} uncached vulnerabilities...", file=sys.stderr)
        batch_results = query_llm_vulnerabilities_batch(uncached_vulns_to_query)
        for vuln_id, explanations in batch_results.items():
            runtime_explanations[vuln_id] = explanations
            if has_llm and not is_failed_explanation(explanations):
                cache_entry = dict(explanations)
                if vuln_id in vuln_id_to_modified and vuln_id_to_modified[vuln_id]:
                    cache_entry["modified"] = vuln_id_to_modified[vuln_id]
                cache[vuln_id] = cache_entry
                cache_updated = True

    for report_path in sorted(reports_dir.glob("osv-*.json")):
        if report_path.name == "osv-summary.json":
            continue
        stem = report_path.stem.removeprefix("osv-")
        if "-" in stem:
            channel, arch = stem.split("-", 1)
        else:
            channel = "stable"
            arch = stem
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
                        )
                        runtime_explanations[vuln_id] = explanations
                        if has_llm and not is_failed_explanation(explanations):
                            cache_entry = dict(explanations)
                            report_modified = v.get("modified", "")
                            if report_modified:
                                cache_entry["modified"] = report_modified
                            cache[vuln_id] = cache_entry
                            cache_updated = True
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
            "channel": channel,
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
            '<span class="p-chip vulnerability-status-badge--actionable">'
            '<span class="p-chip__value">Actionable (USN)</span>'
            '</span>'
        )
    else:
        return (
            '<span class="p-chip vulnerability-status-badge--confined" title="Mitigated by snap confinement">'
            '<span class="p-chip__value">Confined Mitigation</span>'
            '</span>'
        )


def confinement_recommendation_badge(recommendation):
    if recommendation == CONFINEMENT_CONTAINED:
        return (
            '<span class="p-chip confinement-badge--contained" title="No residual risk remains beyond snap confinement">'
            '<span class="p-chip__value">\u2713 Contained by confinement</span>'
            '</span>'
        )
    if recommendation == CONFINEMENT_RESIDUAL:
        return (
            '<span class="p-chip confinement-badge--residual" title="Residual risk extends beyond snap confinement">'
            '<span class="p-chip__value">\u26a0 Residual risk beyond confinement</span>'
            '</span>'
        )
    return ""


# CycloneDX VEX (Vulnerability Exploitability eXchange) generation
#
# The same confinement analysis that backs the HTML and Markdown reports is
# emitted as a standards-compliant CycloneDX 1.5 VEX document per architecture,
# so downstream consumers (and CRA-style audits) can ingest the snap's
# exploitability assessment with off-the-shelf tooling. A "Contained by
# confinement" finding becomes a not_affected / protected_at_runtime claim; a
# finding with residual risk becomes exploitable with a recommended response.

VEX_SPEC_VERSION = "1.5"
VEX_PRODUCT_NAME = "pihole-by-rajannpatel"
# Fixed namespace so a given product/architecture/timestamp resolves to a
# stable serialNumber (reproducible builds and deterministic tests).
VEX_NAMESPACE = uuid.UUID("1b671a64-40d5-491e-99b0-da01ff1f3341")

VEX_STATE_NOT_AFFECTED = "not_affected"
VEX_STATE_EXPLOITABLE = "exploitable"
VEX_STATE_IN_TRIAGE = "in_triage"

# Snap confinement is a runtime control, so a contained finding is expressed
# with the canonical CycloneDX "protected_at_runtime" justification.
VEX_JUSTIFICATION_RUNTIME = "protected_at_runtime"

# OSV CVSS severity word -> CycloneDX rating severity enum.
_VEX_SEVERITY_MAP = {
    "critical": "critical",
    "high": "high",
    "medium": "medium",
    "low": "low",
    "negligible": "info",
}


def vex_filename(channel, architecture):
    return f"vex-{channel}-{architecture}.cdx.json"


def vex_serial_number(architecture, timestamp):
    seed = f"{VEX_PRODUCT_NAME}:{architecture}:{timestamp}"
    return f"urn:uuid:{uuid.uuid5(VEX_NAMESPACE, seed)}"


def _vex_purl(package_name, package_version, architecture):
    purl = f"pkg:deb/ubuntu/{urllib.parse.quote(package_name, safe='')}"
    if package_version:
        purl += f"@{urllib.parse.quote(package_version, safe='')}"
    purl += f"?arch={urllib.parse.quote(architecture, safe='')}"
    return purl


def vex_ratings(severity_text):
    """Map the report's "9.8 · Critical" severity string to CycloneDX ratings."""
    severity_text = (severity_text or "").strip()
    score = None
    parts = severity_text.split("\u00b7")
    if len(parts) == 2:
        try:
            score = float(parts[0].strip())
        except ValueError:
            score = None
    cdx_severity = _VEX_SEVERITY_MAP.get(severity_priority(severity_text), "unknown")
    if score is None and cdx_severity == "unknown":
        return []
    rating = {"source": {"name": "OSV"}, "severity": cdx_severity}
    if score is not None:
        rating["score"] = score
        rating["method"] = "CVSSv3"
    return [rating]


def vex_analysis(appropriate_text, not_appropriate_text, patchable):
    """Translate the confinement analysis into a CycloneDX analysis object.

    A contained finding asserts ``not_affected`` because snap confinement
    protects it at runtime; a finding with residual risk is reported as
    ``exploitable`` with a response that reflects whether an upstream fix
    (USN) exists; an absent or failed analysis stays ``in_triage`` so a lookup
    failure never silently claims containment.
    """
    appropriate = (appropriate_text or "").strip()
    not_appropriate = (not_appropriate_text or "").strip()
    recommendation = confinement_recommendation(appropriate, not_appropriate)
    if recommendation == CONFINEMENT_CONTAINED:
        return {
            "state": VEX_STATE_NOT_AFFECTED,
            "justification": VEX_JUSTIFICATION_RUNTIME,
            "detail": appropriate,
        }
    if recommendation == CONFINEMENT_RESIDUAL:
        if appropriate and not_appropriate:
            detail = f"{appropriate}\n\nResidual risk: {not_appropriate}"
        else:
            detail = not_appropriate or appropriate
        analysis = {
            "state": VEX_STATE_EXPLOITABLE,
            "response": ["update"] if patchable else ["can_not_fix"],
        }
        if detail:
            analysis["detail"] = detail
        return analysis
    return {"state": VEX_STATE_IN_TRIAGE}


def build_vex_vulnerability(vulnerability, package_name, component_ref, architecture):
    vuln_id = display_vulnerability_id(vulnerability.get("id", "unknown"))
    entry = {
        "bom-ref": f"vex-{architecture}-{package_name}-{vuln_id}",
        "id": vuln_id,
    }
    url = vulnerability.get("url")
    if url:
        entry["source"] = {"name": "OSV", "url": url}
    ratings = vex_ratings(vulnerability.get("severity", ""))
    if ratings:
        entry["ratings"] = ratings
    aliases = [
        alias
        for alias in vulnerability.get("aliases", [])
        if alias and alias != vulnerability.get("id")
    ]
    if aliases:
        entry["references"] = [
            {
                "id": alias,
                "source": {"name": "USN" if alias.startswith("USN-") else "OSV"},
            }
            for alias in aliases
        ]
    published = vulnerability.get("published") or vulnerability.get("modified")
    if published:
        entry["published"] = published
    entry["affects"] = [{"ref": component_ref}]
    entry["analysis"] = vex_analysis(
        vulnerability.get("appropriate", ""),
        vulnerability.get("not_appropriate", ""),
        vulnerability.get("patchable", False),
    )
    return entry


def build_vex_document(report, serial_number=None):
    """Build a CycloneDX 1.5 VEX document for a single architecture report."""
    architecture = report["architecture"]
    timestamp = report.get("generatedAt", {}).get("datetime") or (
        datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    )

    components = {}
    vulnerabilities = []
    for package in report.get("packages", []):
        package_name = package.get("name", "unknown")
        package_version = package.get("version", "")
        component_ref = _vex_purl(package_name, package_version, architecture)
        if component_ref not in components:
            component = {
                "type": "library",
                "bom-ref": component_ref,
                "name": package_name,
                "purl": component_ref,
            }
            if package_version:
                component["version"] = package_version
            components[component_ref] = component
        for vulnerability in package.get("vulnerabilities", []):
            vulnerabilities.append(
                build_vex_vulnerability(
                    vulnerability, package_name, component_ref, architecture
                )
            )

    document = {
        "bomFormat": "CycloneDX",
        "specVersion": VEX_SPEC_VERSION,
        "serialNumber": serial_number or vex_serial_number(architecture, timestamp),
        "version": 1,
        "metadata": {
            "timestamp": timestamp,
            "component": {
                "type": "application",
                "bom-ref": f"{VEX_PRODUCT_NAME}@{architecture}",
                "name": VEX_PRODUCT_NAME,
                "purl": f"pkg:snap/{VEX_PRODUCT_NAME}?arch={architecture}",
            },
            "tools": [{"vendor": "snap-pi-hole", "name": "summarize_osv_reports.py"}],
        },
        "vulnerabilities": vulnerabilities,
    }
    if components:
        document["components"] = list(components.values())
    return document


def write_vex_documents(summary, reports_dir):
    """Write one CycloneDX VEX document per architecture report.

    Returns the filenames written so callers and tests can locate them.
    """
    written = []
    for report in summary.get("reports", []):
        document = build_vex_document(report)
        filename = vex_filename(report.get("channel", "stable"), report["architecture"])
        (reports_dir / filename).write_text(
            json.dumps(document, indent=2) + "\n", encoding="utf-8"
        )
        written.append(filename)
    return written


def write_html(summary, output_path):
    summary_rows = []
    detail_rows_by_key = {}

    sorted_reports = sorted(
        summary.get("reports", []),
        key=lambda r: (
            {"amd64": 0, "arm64": 1}.get(r["architecture"].lower(), 99),
            r["architecture"].lower(),
            r.get("channel", "stable").lower()
        )
    )

    for report in sorted_reports:
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
        vex_link = f'<a class="p-button" href="{html.escape(vex_filename(report.get("channel", "stable"), report["architecture"]))}" download>Download VEX</a>'

        report_cell = (
            f'{report_time}<br>'
            f'<div class="vulnerability-report-actions">'
            f'{report_link}{vex_link}</div>'
        )
        
        ch = html.escape(report.get("channel", "stable"))
        summary_rows.append(
            f"<tr>"
            f"<td><span class=\"p-chip\">{ch}</span></td>"
            f"<td><strong>{arch.upper()}</strong></td>"
            f"<td>{actionable_pkgs}</td>"
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
                        "channels": set(),
                        "architectures": set(),
                    }
                detail_rows_by_key[detail_key]["channels"].add(report.get("channel", "stable"))
                detail_rows_by_key[detail_key]["architectures"].add(report["architecture"])

    detail_rows = []
    architecture_order = {"AMD64": 0, "ARM64": 1}
    for row_data in detail_rows_by_key.values():
        channel_labels = sorted(row_data["channels"])
        channel_cells = " ".join(
            channel_chip(channel) for channel in channel_labels
        )
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
                " ".join(channel_labels),
                " ".join(architecture_labels),
                appropriate_text,
                not_appropriate_text,
                recommendation_label,
            ]
        ).lower()
        recommendation_html = ""
        if recommendation:
            recommendation_html = (
                f'<div class="confinement-recommendation">'
                f'{confinement_recommendation_badge(recommendation)}'
                f'</div>'
            )
        explanation_blocks = []
        if appropriate_text:
            explanation_blocks.append(
                f'<div class="vulnerability-explanation vulnerability-explanation--contained">'
                f'<h4 class="vulnerability-explanation__title">Snap confinement mitigates risk</h4>'
                f'<p class="vulnerability-explanation__body">{html.escape(appropriate_text)}</p>'
                f'</div>'
            )
        if not_appropriate_text:
            explanation_blocks.append(
                f'<div class="vulnerability-explanation vulnerability-explanation--residual">'
                f'<h4 class="vulnerability-explanation__title">Risk boundary extends beyond snap confinement</h4>'
                f'<p class="vulnerability-explanation__body">{html.escape(not_appropriate_text)}</p>'
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
            f"<td>{channel_cells}</td>"
            f"<td>{architecture_cells}</td>"
            "</tr>\n"
        )
        if explanation_blocks:
            detail_row_html += (
                f'<tr class="vulnerability-explanation-row">'
                f'<td class="vulnerability-explanation-cell" colspan="9">'
                f'{recommendation_html}'
                f'<div class="vulnerability-explanation-grid">'
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
        '<tr><td colspan="9">No unpatched vulnerabilities reported by OSV-Scanner.</td></tr>'
    )
    css_source = pathlib.Path(__file__).resolve().parent.parent / "assets" / "vulnerability-report.css"
    css_target = output_path.parent / "vulnerability-report.css"
    css_target.write_text(css_source.read_text(encoding="utf-8"), encoding="utf-8")
    output_path.write_text(f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Vulnerability Reports - snap Pi-hole</title>
{vanilla_framework_css_link()}
  <link rel="stylesheet" href="vulnerability-report.css">
</head>
<body>
  <div class="l-site">
    <header id="navigation" class="p-navigation is-dark">
      <div class="p-navigation__row">
        <div class="p-navigation__banner">
          <a class="p-navigation__link navigation-logo-link" href="../">
            <img src="../pihole.png" alt="Pi-hole Logo" class="navigation-logo-img">
          </a>
        </div>
      </div>
    </header>

    <main class="p-strip">
      <div class="row">
        <div class="col-12">
          <nav class="p-breadcrumbs vulnerability-breadcrumbs" aria-label="Breadcrumbs">
            <ol class="p-breadcrumbs__items">
              <li class="p-breadcrumbs__item"><a href="../">Reports Dashboard</a></li>
              <li class="p-breadcrumbs__item" aria-current="page">Vulnerability Reports</li>
            </ol>
          </nav>
          <section class="row vulnerability-header" aria-labelledby="vulnerability-title">
            <div class="col-12">
              <h1 class="p-heading--2 vulnerability-title" id="vulnerability-title">Vulnerability Reports</h1>
              <p class="p-heading--4">OSV-Scanner findings from the generated SBOMs.</p>
            </div>
          </section>
          
          <div class="p-strip vulnerability-confinement-note">
            <h3 class="p-heading--4 vulnerability-confinement-note__title">The value of snap confinement</h3>
            <p class="vulnerability-confinement-note__body">
              This report contains both <strong>Actionable</strong> (USN available) and <strong>Confined Mitigation</strong> (no USN or official patch available upstream) findings.
            </p>
            <p class="vulnerability-confinement-note__body">
              The CI workflow publishes OSV reports for visibility and fails only when the scanner itself errors. Known-vulnerability exit code 1 is treated as a warning. Unlike conventional deployments, a strictly confined snap executes within a sandbox: process capabilities and host interactions are restricted by <strong>AppArmor profiles, seccomp filters, and a read-only SquashFS filesystem</strong>.
            </p>
          </div>

          <h2 class="p-heading--3">Vulnerability Summary</h2>
          <div class="vulnerability-table-wrap vulnerability-table-wrap--summary">
            <table class="p-table" id="vulnerability-summary-table">
              <thead>
                <tr>
                  <th>Channel</th>
                  <th>Architecture</th>
                  <th>Published Fixes (USN)</th>
                  <th>CVE Matches</th>
                  <th>Confined Mitigations</th>
                  <th>Report</th>
                </tr>
              </thead>
              <tbody>
                {summary_table_rows}
              </tbody>
            </table>
          </div>
          <p class="p-text--small vulnerability-summary-note">
            Actionable counts include only vulnerability matches with a corresponding Ubuntu Security Notice (USN). Confined mitigations represent report-only matches that are sandboxed by snap confinement. <strong>Download VEX</strong> exports each architecture's confinement analysis as a standards-compliant CycloneDX VEX document.
          </p>
          <h2 class="p-heading--3">Vulnerability Details</h2>
          <div class="vulnerability-table-controls">
            <!-- Search Box -->
            <div class="vulnerability-search-wrap">
              <form class="p-search-box vulnerability-search-form" onsubmit="event.preventDefault(); filterVulnerabilities();">
                <label class="u-off-screen" for="vulnerability-search">Search by package, version, vulnerability, CVSS 3, priority, status, publication date, or architecture</label>
                <input type="search" id="vulnerability-search" class="p-search-box__input" placeholder="Search by package, version, vulnerability, CVSS 3, priority, status, publication date, architecture, or confinement analysis..." oninput="filterVulnerabilities()" autocomplete="off">
                <button type="reset" class="p-search-box__reset" onclick="document.getElementById('vulnerability-search').value=''; filterVulnerabilities();"><i class="p-icon--close">Clear</i></button>
                <button type="submit" class="p-search-box__button"><i class="p-icon--search">Search</i></button>
              </form>
            </div>
            <!-- Channel Filter -->
            <div class="vulnerability-filter-dropdown-wrap">
              <label for="filter-channel" class="vulnerability-filter-label">Channel:</label>
              <select id="filter-channel" onchange="filterVulnerabilities()" class="vulnerability-filter-select">
                <option value="">All Channels</option>
                <option value="stable">Stable</option>
                <option value="edge">Edge</option>
              </select>
            </div>
            <!-- Architecture Filter -->
            <div class="vulnerability-filter-dropdown-wrap">
              <label for="filter-arch" class="vulnerability-filter-label">Architecture:</label>
              <select id="filter-arch" onchange="filterVulnerabilities()" class="vulnerability-filter-select">
                <option value="">All Architectures</option>
                <option value="amd64">AMD64</option>
                <option value="arm64">ARM64</option>
              </select>
            </div>
          </div>
          <div class="vulnerability-table-wrap">
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
                  <th><button type="button" class="vulnerability-sort-button" data-column="7" aria-sort="none" onclick="sortVulnerabilities(7)">Channels</button></th>
                  <th><button type="button" class="vulnerability-sort-button" data-column="8" aria-sort="none" onclick="sortVulnerabilities(8)">Architectures</button></th>
                </tr>
              </thead>
              <tbody id="vulnerability-tbody">
                {detail_body_rows}
              </tbody>
            </table>
          </div>
          <p class="p-text--small">Full OSV JSON reports and CycloneDX VEX documents are linked in the summary table.</p>
        </div>
      </div>
    </main>

    <footer class="p-strip--dark">
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

      const filterChannel = document.getElementById('filter-channel');
      const channelVal = filterChannel ? filterChannel.value.toLowerCase() : '';

      const filterArch = document.getElementById('filter-arch');
      const archVal = filterArch ? filterArch.value.toLowerCase() : '';

      const rows = document.querySelectorAll('#vulnerability-tbody tr.vulnerability-row');
      rows.forEach(row => {{
        const nextRow = row.nextElementSibling;
        const searchText = row.dataset.search || row.textContent.toLowerCase();
        let matches = !query || searchText.includes(query);

        if (matches && (channelVal || archVal)) {{
          let channelMatches = !channelVal;
          let archMatches = !archVal;

          if (channelVal) {{
            const channelChips = Array.from(row.querySelectorAll('.vulnerability-channel .p-chip__value')).map(c => c.textContent.trim().toLowerCase());
            if (channelChips.includes(channelVal)) {{
              channelMatches = true;
            }}
          }}
          if (archVal) {{
            const archChips = Array.from(row.querySelectorAll('.vulnerability-architecture .p-chip__value')).map(c => c.textContent.trim().toLowerCase());
            if (archChips.includes(archVal)) {{
              archMatches = true;
            }}
          }}
          if (!channelMatches || !archMatches) {{
            matches = false;
          }}
        }}

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
    write_vex_documents(summary, reports_dir)


if __name__ == "__main__":
    main()
