#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TEST_TMPDIR="$(mktemp -d)"
    REPORT_DIR="${TEST_TMPDIR}/vulnerability-reports"
    mkdir -p "$REPORT_DIR"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

write_osv_report() {
    local path="$1"
    cat > "$path" <<'EOF'
{
  "results": [
    {
      "packages": [
        {
          "package": {
            "name": "curl",
            "version": "7.88.1-10+deb12u1",
            "ecosystem": "Ubuntu"
          },
          "vulnerabilities": [
            {
              "id": "CVE-2023-38545",
              "aliases": ["USN-6425-1"],
              "summary": "USN-backed curl vulnerability",
              "published": "2023-10-11T12:00:00Z"
            },
            {
              "id": "CVE-2023-99999",
              "aliases": [],
              "summary": "Non-USN OSV finding",
              "published": "2023-12-01T12:00:00Z"
            }
          ]
        }
      ]
    }
  ]
}
EOF
}

@test "OSV summary separates unique actionable USN counts from raw architecture matches" {
    write_osv_report "${REPORT_DIR}/osv-amd64.json"
    write_osv_report "${REPORT_DIR}/osv-arm64.json"

    python3 "${REPO_ROOT}/snap/local/build/summarize_osv_reports.py" "$REPORT_DIR"

    run jq -e '
      .totalVulnerabilities == 2 and
      .affectedPackages == 1 and
      .actionableVulnerabilities == 1 and
      .actionableAffectedPackages == 1 and
      .confinedMitigationVulnerabilities == 1 and
      ([.reports[].vulnerabilities] == [2, 2]) and
      ([.reports[].actionableVulnerabilities] == [1, 1]) and
      ([.reports[].confinedMitigationVulnerabilities] == [1, 1])
    ' "${REPORT_DIR}/osv-summary.json"
    [ "$status" -eq 0 ]
}

@test "dashboard security summary uses actionable USN counts, not raw OSV matches" {
    write_osv_report "${REPORT_DIR}/osv-amd64.json"
    write_osv_report "${REPORT_DIR}/osv-arm64.json"
    python3 "${REPO_ROOT}/snap/local/build/summarize_osv_reports.py" "$REPORT_DIR"

    python3 - <<PYEOF
import pathlib
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import collect_security_summary

security = collect_security_summary(pathlib.Path("${REPORT_DIR}/osv-summary.json"))
assert security["total_vulnerabilities"] == 1, security
assert security["affected_packages"] == 1, security
assert security["raw_vulnerability_matches"] == 2, security
assert security["raw_affected_packages"] == 1, security
assert security["confined_mitigation_vulnerabilities"] == 1, security
assert security["gate_policy"] == "report_only", security
for row in security["architectures"]:
    assert row["vulnerabilities"] == 1, row
    assert row["affected_packages"] == 1, row
    assert row["raw_vulnerability_matches"] == 2, row
PYEOF
}

@test "dashboard security summary is zero when OSV findings have no USN" {
    cat > "${REPORT_DIR}/osv-amd64.json" <<'EOF'
{
  "results": [
    {
      "packages": [
        {
          "package": {"name": "curl", "version": "7.88.1", "ecosystem": "Ubuntu"},
          "vulnerabilities": [
            {"id": "CVE-2023-99999", "aliases": [], "summary": "No USN"}
          ]
        }
      ]
    }
  ]
}
EOF
    python3 "${REPO_ROOT}/snap/local/build/summarize_osv_reports.py" "$REPORT_DIR"

    python3 - <<PYEOF
import pathlib
import sys
sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
from generate_dashboard_data import collect_security_summary

security = collect_security_summary(pathlib.Path("${REPORT_DIR}/osv-summary.json"))
assert security["total_vulnerabilities"] == 0, security
assert security["affected_packages"] == 0, security
assert security["raw_vulnerability_matches"] == 1, security
assert security["raw_affected_packages"] == 1, security
assert security["confined_mitigation_vulnerabilities"] == 1, security
PYEOF
}

@test "OSV summary detects USNs from related IDs and reference URLs" {
    cat > "${REPORT_DIR}/osv-amd64.json" <<'EOF'
{
  "results": [
    {
      "packages": [
        {
          "package": {"name": "openssl", "version": "3.0.13", "ecosystem": "Ubuntu"},
          "vulnerabilities": [
            {
              "id": "CVE-2026-0001",
              "related": ["USN-7001-1"],
              "aliases": [],
              "summary": "Related USN marks this actionable"
            },
            {
              "id": "CVE-2026-0002",
              "aliases": [],
              "references": [
                {"url": "https://ubuntu.com/security/notices/USN-7002-1"}
              ],
              "summary": "Reference URL marks this actionable"
            },
            {
              "id": "CVE-2026-0003",
              "aliases": [],
              "related": [],
              "references": [{"url": "https://example.test/advisory"}],
              "summary": "No USN stays report-only"
            }
          ]
        }
      ]
    }
  ]
}
EOF

    python3 "${REPO_ROOT}/snap/local/build/summarize_osv_reports.py" "$REPORT_DIR"

    python3 - <<PYEOF
import json
from pathlib import Path

summary = json.loads(Path("${REPORT_DIR}/osv-summary.json").read_text())
report = summary["reports"][0]
patchable = {
    vulnerability["id"]: vulnerability["patchable"]
    for package in report["packages"]
    for vulnerability in package["vulnerabilities"]
}

assert patchable == {
    "CVE-2026-0001": True,
    "CVE-2026-0002": True,
    "CVE-2026-0003": False,
}, patchable
assert report["actionableVulnerabilities"] == 2, report
assert report["confinedMitigationVulnerabilities"] == 1, report
assert summary["actionableVulnerabilities"] == 2, summary
assert summary["confinedMitigationVulnerabilities"] == 1, summary
PYEOF
}

@test "OSV summary emits empty reports and generated artifacts for empty directory" {
    python3 "${REPO_ROOT}/snap/local/build/summarize_osv_reports.py" "$REPORT_DIR"

    run jq -e '
      .reports == [] and
      .totalVulnerabilities == 0 and
      .affectedPackages == 0 and
      .actionableVulnerabilities == 0 and
      .confinedMitigationVulnerabilities == 0
    ' "${REPORT_DIR}/osv-summary.json"
    [ "$status" -eq 0 ]

    [ -s "${REPORT_DIR}/vuln-summary.md" ]
    [ -s "${REPORT_DIR}/index.html" ]
}

@test "LLM query uses header auth with configurable endpoint and default model" {
    python3 - <<PYEOF
import json
import os
import sys
from unittest import mock

sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import summarize_osv_reports as summary

class DummyResponse:
    def __init__(self, payload):
        self._payload = payload

    def read(self):
        return json.dumps(self._payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

captured = {}

def fake_urlopen(req, timeout=0):
    captured["url"] = req.full_url
    captured["api_key"] = req.get_header("Authorization")
    captured["body"] = json.loads(req.data.decode("utf-8"))
    payload = {
        "choices": [
            {
                "message": {
                    "content": json.dumps({"appropriate": "A", "not_appropriate": "B"})
                }
            }
        ]
    }
    return DummyResponse(payload)

with mock.patch.dict(
    os.environ,
    {
        "LLM_API_KEY": "test-key",
        "LLM_API_BASE_URL": "https://example.test",
        "LLM_MAX_ATTEMPTS": "1",
    },
    clear=False,
):
    with mock.patch("summarize_osv_reports.urllib.request.urlopen", side_effect=fake_urlopen):
        result = summary.query_vulnerability_info("CVE-2026-1000", "curl", "1.0")
        assert result == {"appropriate": "A", "not_appropriate": "B"}, result
        assert "https://example.test/chat/completions" == captured["url"], captured
        assert "Bearer test-key" == captured["api_key"], captured
        assert captured["body"]["model"] == summary.DEFAULT_MODEL, captured
PYEOF
}

@test "LLM query retries rate-limits and falls back on auth errors" {
    python3 - <<PYEOF
import io
import json
import os
import sys
import urllib.error
from unittest import mock

sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import summarize_osv_reports as summary

class DummyResponse:
    def __init__(self, payload):
        self._payload = payload

    def read(self):
        return json.dumps(self._payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

retry_state = {"count": 0}

def flaky_then_success(req, timeout=0):
    retry_state["count"] += 1
    if retry_state["count"] == 1:
        raise urllib.error.HTTPError(
            req.full_url,
            429,
            "rate-limited",
            hdrs=None,
            fp=io.BytesIO(b'{"error":"too many requests"}'),
        )
    payload = {
        "choices": [
            {
                "message": {
                    "content": json.dumps({"appropriate": "retry-ok", "not_appropriate": "retry-risk"})
                }
            }
        ]
    }
    return DummyResponse(payload)

with mock.patch.dict(
    os.environ,
    {
        "LLM_API_KEY": "test-key",
        "LLM_MAX_ATTEMPTS": "2",
        "LLM_RETRY_BASE_DELAY_SECONDS": "0",
    },
    clear=False,
):
    with mock.patch("summarize_osv_reports.urllib.request.urlopen", side_effect=flaky_then_success):
        with mock.patch("summarize_osv_reports.time.sleep", return_value=None):
            result = summary.query_vulnerability_info("CVE-2026-1001", "curl", "1.0")
            assert result["appropriate"] == "retry-ok", result
            assert retry_state["count"] == 2, retry_state

auth_error = urllib.error.HTTPError(
    "https://example.test",
    401,
    "unauthorized",
    hdrs=None,
    fp=io.BytesIO(b'{"error":"invalid key"}'),
)
with mock.patch.dict(os.environ, {"LLM_API_KEY": "bad-key", "LLM_MAX_ATTEMPTS": "1"}, clear=False):
    with mock.patch("summarize_osv_reports.urllib.request.urlopen", side_effect=auth_error):
        result = summary.query_vulnerability_info("CVE-2026-1002", "curl", "1.0")
        assert "error during LLM lookup" in result["appropriate"], result
        assert "error during LLM lookup" in result["not_appropriate"], result
PYEOF
}

@test "LLM query falls back after malformed responses" {
    python3 - <<PYEOF
import json
import os
import sys
from unittest import mock

sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import summarize_osv_reports as summary

class DummyResponse:
    def __init__(self, payload):
        self._payload = payload

    def read(self):
        return json.dumps(self._payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

payload = {"choices": [{"message": {"content": "not valid json"}}]}

with mock.patch.dict(
    os.environ,
    {
        "LLM_API_KEY": "test-key",
        "LLM_MAX_ATTEMPTS": "2",
        "LLM_RETRY_BASE_DELAY_SECONDS": "0",
    },
    clear=False,
):
    with mock.patch("summarize_osv_reports.urllib.request.urlopen", return_value=DummyResponse(payload)):
        with mock.patch("summarize_osv_reports.time.sleep", return_value=None):
            result = summary.query_vulnerability_info("CVE-2026-1003", "curl", "1.0")
            assert "error during LLM lookup" in result["appropriate"], result
            assert "error during LLM lookup" in result["not_appropriate"], result
PYEOF
}

@test "validate_llm_key prints notice and exits 0 when key is absent" {
    python3 - <<PYEOF
import os
import sys
from unittest import mock
from io import StringIO

sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import validate_llm_key

env = {k: v for k, v in os.environ.items() if k != "LLM_API_KEY"}
with mock.patch.dict(os.environ, env, clear=True):
    out = StringIO()
    with mock.patch("sys.stdout", out):
        rc = validate_llm_key.main()
assert rc == 0, f"expected 0, got {rc}"
assert "LLM_API_KEY is unavailable" in out.getvalue(), out.getvalue()
PYEOF
}

@test "validate_llm_key returns 0 on a successful API response" {
    python3 - <<PYEOF
import json
import os
import sys
from unittest import mock

sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import validate_llm_key

captured = {}

class DummyResponse:
    def __init__(self):
        self._data = {
            "choices": [
                {"message": {"content": "ok"}}
            ]
        }
    def read(self):
        return json.dumps(self._data).encode("utf-8")
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return False

def fake_urlopen(req, timeout=0):
    captured["url"] = req.full_url
    captured["api_key"] = req.get_header("Authorization")
    return DummyResponse()

with mock.patch.dict(os.environ, {"LLM_API_KEY": "test-key"}, clear=False):
    with mock.patch("validate_llm_key.urllib.request.urlopen", side_effect=fake_urlopen):
        rc = validate_llm_key.main()
assert rc == 0, f"expected 0, got {rc}"
assert captured["url"] == "https://models.github.ai/inference/chat/completions", captured
assert captured["api_key"] == "Bearer test-key", captured
PYEOF
}

@test "validate_llm_key returns 1 and emits error annotation on HTTP failure" {
    python3 - <<PYEOF
import io
import os
import sys
import urllib.error
from unittest import mock

sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import validate_llm_key

auth_error = urllib.error.HTTPError(
    "https://example.test",
    401,
    "unauthorized",
    hdrs=None,
    fp=io.BytesIO(b'{"error":"invalid key"}'),
)
err_buf = io.StringIO()
with mock.patch.dict(os.environ, {"LLM_API_KEY": "bad-key"}, clear=False):
    with mock.patch("validate_llm_key.urllib.request.urlopen", side_effect=auth_error):
        with mock.patch("sys.stderr", err_buf):
            rc = validate_llm_key.main()
assert rc == 1, f"expected 1, got {rc}"
assert "::error title=LLM key validation::" in err_buf.getvalue(), err_buf.getvalue()
assert "401" in err_buf.getvalue(), err_buf.getvalue()
PYEOF
}

@test "validate_llm_key retries 503 and degrades gracefully returning 0" {
    python3 - <<PYEOF
import io
import os
import sys
import urllib.error
from unittest import mock

sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import validate_llm_key

auth_error = urllib.error.HTTPError(
    "https://example.test",
    503,
    "service unavailable",
    hdrs=None,
    fp=io.BytesIO(b'{"error":"overloaded"}'),
)
err_buf = io.StringIO()
calls = []
def fake_urlopen(*args, **kwargs):
    calls.append(args)
    raise auth_error

with mock.patch.dict(
    os.environ,
    {
        "LLM_API_KEY": "test-key",
        "LLM_MAX_ATTEMPTS": "2",
        "LLM_RETRY_BASE_DELAY_SECONDS": "0",
    },
    clear=False,
):
    with mock.patch("validate_llm_key.urllib.request.urlopen", side_effect=fake_urlopen):
        with mock.patch("validate_llm_key.time.sleep", return_value=None):
            with mock.patch("sys.stderr", err_buf):
                rc = validate_llm_key.main()
assert rc == 0, f"expected 0, got {rc}"
assert len(calls) == 2, f"expected 2 attempts, got {len(calls)}"
assert "::warning title=LLM key validation::" in err_buf.getvalue(), err_buf.getvalue()
assert "503" in err_buf.getvalue(), err_buf.getvalue()
PYEOF
}

@test "validate_llm_key extracts rate limit delay from 429 response body" {
    python3 - <<PYEOF
import io
import os
import sys
import urllib.error
from unittest import mock

sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import validate_llm_key

rate_limit_error = urllib.error.HTTPError(
    "https://example.test",
    429,
    "Too Many Requests",
    hdrs=None,
    fp=io.BytesIO(b'{"message": "Please retry in 50.72s."}'),
)
err_buf = io.StringIO()
calls = []
def fake_urlopen(*args, **kwargs):
    calls.append(args)
    raise rate_limit_error

slept_durations = []
def fake_sleep(seconds):
    slept_durations.append(seconds)

with mock.patch.dict(
    os.environ,
    {
        "LLM_API_KEY": "test-key",
        "LLM_MAX_ATTEMPTS": "2",
        "LLM_RETRY_BASE_DELAY_SECONDS": "1.0",
    },
    clear=False,
):
    with mock.patch("validate_llm_key.urllib.request.urlopen", side_effect=fake_urlopen):
        with mock.patch("validate_llm_key.time.sleep", side_effect=fake_sleep):
            with mock.patch("sys.stderr", err_buf):
                rc = validate_llm_key.main()
assert rc == 0, f"expected 0, got {rc}"
assert len(calls) == 2, f"expected 2 attempts, got {len(calls)}"
assert len(slept_durations) == 1, slept_durations
assert 51.21 <= slept_durations[0] <= 51.23, slept_durations
assert "Rate limit detected. Sleeping for 51.22s" in err_buf.getvalue(), err_buf.getvalue()
PYEOF
}

@test "LLM query processes batch requests and populates cache correctly" {
    python3 - <<PYEOF
import json
import os
import sys
from unittest import mock

sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import summarize_osv_reports as summary

class DummyResponse:
    def __init__(self, payload):
        self._payload = payload

    def read(self):
        return json.dumps(self._payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

# Mock payload returning a single JSON response containing entries for both CVEs
mock_json_content = json.dumps({
    "CVE-2026-9999": {
        "appropriate": "Confinement restricts access.",
        "not_appropriate": "Host bypass possible."
    },
    "CVE-2026-8888": {
        "appropriate": "Sandbox mitigates risk.",
        "not_appropriate": "Bypasses seccomp."
    }
})

payload = {
    "choices": [
        {
            "message": {
                "content": mock_json_content
            }
        }
    ]
}

vulns = [
    {"cve_id": "CVE-2026-9999", "package_name": "curl", "version": "1.0"},
    {"cve_id": "CVE-2026-8888", "package_name": "git", "version": "2.0"}
]

with mock.patch.dict(
    os.environ,
    {
        "LLM_API_KEY": "test-key",
        "LLM_MAX_ATTEMPTS": "1",
    },
    clear=False,
):
    with mock.patch("summarize_osv_reports.urllib.request.urlopen", return_value=DummyResponse(payload)):
        res = summary.query_llm_vulnerabilities_batch(vulns)
        assert len(res) == 2, res
        assert res["CVE-2026-9999"]["appropriate"] == "Confinement restricts access.", res
        assert res["CVE-2026-8888"]["appropriate"] == "Sandbox mitigates risk.", res
PYEOF
}

@test "select_best_model picks the newest free-tier OpenAI text model" {
    python3 - <<PYEOF
import json
import sys
from unittest import mock

sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import llm_model

class DummyResponse:
    def __init__(self, payload):
        self._payload = payload

    def read(self):
        return json.dumps(self._payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

catalog = [
    {"id": "openai/gpt-4o", "publisher": "OpenAI", "rate_limit_tier": "high",
     "version": "2024-11-20", "supported_input_modalities": ["text"],
     "supported_output_modalities": ["text"]},
    {"id": "openai/gpt-4.1", "publisher": "OpenAI", "rate_limit_tier": "high",
     "version": "2025-04-14", "supported_input_modalities": ["text"],
     "supported_output_modalities": ["text"]},
    {"id": "openai/gpt-4.1-mini", "publisher": "OpenAI", "rate_limit_tier": "low",
     "version": "2025-04-14", "supported_input_modalities": ["text"],
     "supported_output_modalities": ["text"]},
    {"id": "openai/gpt-5", "publisher": "OpenAI", "rate_limit_tier": "custom",
     "version": "2025-08-07", "supported_input_modalities": ["text"],
     "supported_output_modalities": ["text"]},
    {"id": "other/flagship", "publisher": "NotOpenAI", "rate_limit_tier": "high",
     "version": "2026-01-01", "supported_input_modalities": ["text"],
     "supported_output_modalities": ["text"]},
    {"id": "openai/text-embedding-3-large", "publisher": "OpenAI",
     "rate_limit_tier": "embeddings", "version": "2024-01-25",
     "supported_input_modalities": ["text"], "supported_output_modalities": ["embeddings"]},
]

with mock.patch("llm_model.urllib.request.urlopen", return_value=DummyResponse(catalog)):
    selected = llm_model.select_best_model("test-key")
    assert selected == "openai/gpt-4.1", selected
PYEOF
}

@test "select_best_model falls back to the default model on catalog failure" {
    python3 - <<PYEOF
import sys
import urllib.error
from unittest import mock

sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import llm_model

with mock.patch(
    "llm_model.urllib.request.urlopen",
    side_effect=urllib.error.URLError("network down"),
):
    selected = llm_model.select_best_model("test-key")
    assert selected == llm_model.DEFAULT_MODEL, selected
PYEOF
}

@test "LLM query splits large vulnerability sets into token-limited batches" {
    python3 - <<PYEOF
import json
import os
import re
import sys
from unittest import mock

sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import summarize_osv_reports as summary

class DummyResponse:
    def __init__(self, payload):
        self._payload = payload

    def read(self):
        return json.dumps(self._payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

call_sizes = []

def fake_urlopen(req, timeout=0):
    content = json.loads(req.data.decode("utf-8"))["messages"][0]["content"]
    # Batch entries use the lowercase "cve" key; the prompt's example output
    # keys CVEs differently, so this counts only the data actually sent.
    batch_ids = re.findall(r'"cve":\s*"([^"]+)"', content)
    call_sizes.append(len(batch_ids))
    answer = {cid: {"appropriate": f"a-{cid}", "not_appropriate": f"n-{cid}"} for cid in batch_ids}
    return DummyResponse({"choices": [{"message": {"content": json.dumps(answer)}}]})

vulns = [
    {"cve_id": f"CVE-3001-{i:04d}", "package_name": "jq", "version": "1.0", "details": "short"}
    for i in range(1, 26)
]

with mock.patch.dict(
    os.environ,
    {"LLM_API_KEY": "test-key", "LLM_MAX_ATTEMPTS": "1"},
    clear=False,
):
    with mock.patch("summarize_osv_reports.time.sleep"):
        with mock.patch("summarize_osv_reports.urllib.request.urlopen", side_effect=fake_urlopen):
            res = summary.query_llm_vulnerabilities_batch(vulns)

assert len(res) == 25, len(res)
assert all(v["cve_id"] in res for v in vulns), res.keys()
# 25 vulns capped at MAX_VULNS_PER_BATCH=10 -> 3 requests (10, 10, 5).
assert len(call_sizes) == 3, call_sizes
assert max(call_sizes) <= summary.MAX_VULNS_PER_BATCH, call_sizes
assert sum(call_sizes) == 25, call_sizes
assert res["CVE-3001-0025"]["appropriate"] == "a-CVE-3001-0025", res["CVE-3001-0025"]
PYEOF
}

@test "build_analysis_prompt truncates overly long vulnerability details" {
    python3 - <<PYEOF
import sys

sys.path.insert(0, "${REPO_ROOT}/snap/local/build")
import summarize_osv_reports as summary

long_details = "X" * 5000
prompt = summary.build_analysis_prompt([
    {"cve_id": "CVE-3002-0001", "package_name": "jq", "version": "1.0", "details": long_details}
])
# The 5000-char detail must be truncated to the cap (plus an ellipsis marker).
assert ("X" * summary.MAX_DETAILS_CHARS) in prompt, "expected truncated run of X"
assert ("X" * (summary.MAX_DETAILS_CHARS + 1)) not in prompt, "details exceeded cap"
PYEOF
}

