#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
}

check_balance() {
    python3 - "$1" <<'PYEOF'
import sys
from html.parser import HTMLParser

VOID = {
    "area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "param", "source", "track", "wbr",
}


class BalanceParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.defects = []

    def handle_starttag(self, tag, attrs):
        if tag not in VOID:
            self.stack.append((tag, self.getpos()[0]))

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i][0] == tag:
                for inner_tag, line in self.stack[i + 1:]:
                    self.defects.append(
                        f"<{inner_tag}> opened at line {line} not closed "
                        f"before </{tag}> at line {self.getpos()[0]}"
                    )
                del self.stack[i:]
                return
        self.defects.append(f"stray </{tag}> at line {self.getpos()[0]}")


path = sys.argv[1]
parser = BalanceParser()
parser.feed(open(path, encoding="utf-8").read())
for tag, line in parser.stack:
    parser.defects.append(f"<{tag}> opened at line {line} never closed (EOF)")

if parser.defects:
    print(f"Unbalanced markup in {path}:")
    for defect in parser.defects:
        print(f"  - {defect}")
    sys.exit(1)
PYEOF
}

@test "dashboard.html has balanced block markup" {
    run check_balance "${REPO_ROOT}/snap/local/assets/dashboard.html"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "dashboard status-caution chips have explicit contrast styles" {
    python3 - <<PYEOF
import pathlib
import re

repo = pathlib.Path("${REPO_ROOT}")
for rel in ("snap/local/assets/dashboard.css",):
    text = (repo / rel).read_text(encoding="utf-8")
    match = re.search(r"\\.status-caution\\s*\\{([^}]+)\\}", text, re.S)
    assert match, f"{rel} does not define .status-caution"
    body = match.group(1)
    assert "background:" in body, f"{rel} .status-caution has no background"
    assert "color:" in body, f"{rel} .status-caution has no text color"
PYEOF
}

@test "report templates use external stylesheets without inline CSS" {
    python3 - <<PYEOF
import pathlib
import re

repo = pathlib.Path("${REPO_ROOT}")
checks = {
    "snap/local/assets/dashboard.html": "dashboard.css",
    "snap/local/assets/sbom-explorer.html": "sbom-explorer.css",
}
for rel, css_href in checks.items():
    text = (repo / rel).read_text(encoding="utf-8")
    assert f'rel="stylesheet" href="{css_href}"' in text, f"{rel} missing {css_href} link"
    assert "<style" not in text.lower(), f"{rel} should not contain inline <style> blocks"
    assert not re.search(r"\\sstyle\\s*=", text, re.I), f"{rel} should not contain style attributes"
PYEOF
}

@test "report generators do not emit inline CSS" {
    python3 - <<PYEOF
import pathlib
import re

repo = pathlib.Path("${REPO_ROOT}")
for rel in ("snap/local/build/prettify_coverage.py", "snap/local/build/summarize_osv_reports.py"):
    text = (repo / rel).read_text(encoding="utf-8")
    assert "<style" not in text.lower(), f"{rel} should not emit inline <style> blocks"
    assert not re.search(r"\\sstyle\\s*=", text, re.I), f"{rel} should not emit style attributes"
PYEOF
}

@test "dashboard uses explicit GitHub and Launchpad builder labels" {
    python3 - <<PYEOF
import pathlib

repo = pathlib.Path("${REPO_ROOT}")
for rel in ("snap/local/assets/dashboard.html",):
    text = (repo / rel).read_text(encoding="utf-8")
    assert "status-chip--github-builder" in text, f"{rel} missing GitHub builder chip class"
    assert "status-chip--launchpad-builder" in text, f"{rel} missing Launchpad builder chip class"
    assert "GitHub builder" in text, f"{rel} missing GitHub builder label"
    assert "Launchpad builder" in text, f"{rel} missing Launchpad builder label"
PYEOF
}

@test "sbom-explorer.html has balanced block markup" {
    run check_balance "${REPO_ROOT}/snap/local/assets/sbom-explorer.html"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "dashboard workflow tables use duration columns and colspan 5" {
    python3 - <<PYEOF
import pathlib
repo = pathlib.Path("${REPO_ROOT}")
for rel in ("snap/local/assets/dashboard.html",):
    text = (repo / rel).read_text(encoding="utf-8")
    assert "<th>Test duration</th>" in text, f"{rel} missing test duration column"
    assert "<th>Sync duration</th>" in text, f"{rel} missing sync duration column"
    assert "<th>Build/publish duration</th>" in text, f"{rel} missing build/publish duration column"
    snap_columns = [
        "<th>Version</th>",
        "<th>Revision</th>",
        "<th>Size</th>",
        "<th>Released</th>",
        "<th>Latest build status</th>",
        "<th>Build/publish duration</th>",
    ]
    cursor = -1
    for column in snap_columns:
        cursor = text.find(column, cursor + 1)
        assert cursor != -1, f"{rel} snap package columns out of order near {column}"
    assert 'colspan="5">Loading dependency comparisons...' in text, f"{rel} missing colspan 5 loading row"
PYEOF
}

@test "dashboard vulnerability summary table explains action and report-only findings" {
    python3 - <<PYEOF
import pathlib
repo = pathlib.Path("${REPO_ROOT}")
for rel in ("snap/local/assets/dashboard.html",):
    text = (repo / rel).read_text(encoding="utf-8")
    assert "<h2>Vulnerability summary</h2>" in text, f"{rel} missing vulnerability summary heading"
    assert "<th>Action needed</th>" in text, f"{rel} missing action-needed column"
    assert "<th>Report-only findings</th>" in text, f"{rel} missing report-only column"
    assert "<th>CVE matches</th>" in text, f"{rel} missing CVE matches column"
    assert "<th>Evidence</th>" in text, f"{rel} missing evidence column"
    assert 'colspan="6">Loading vulnerability summary...' in text, f"{rel} loading row colspan is stale"
    assert "No USN action" in text, f"{rel} missing clear action label"
    assert "Review \${actionable} USN" in text, f"{rel} missing actionable review label"
    assert "OSV JSON" in text and "VEX JSON" in text, f"{rel} evidence buttons are unclear"
PYEOF
}

@test "dashboard exposes channel scope and current activity summary" {
    python3 - <<PYEOF
import pathlib
repo = pathlib.Path("${REPO_ROOT}")
for rel in ("snap/local/assets/dashboard.html",):
    text = (repo / rel).read_text(encoding="utf-8")
    assert 'id="channel-scope-summary"' in text, f"{rel} missing channel scope summary"
    assert 'id="current-activity"' in text, f"{rel} missing current activity strip"
    for label in ("Upstream", "Build", "Store", "Install"):
        assert f'>{label}</span>' in text, f"{rel} missing activity label {label}"
PYEOF
}

@test "dashboard report library separates vulnerability CTA from tabbed channel selector" {
    python3 - <<PYEOF
import pathlib
repo = pathlib.Path("${REPO_ROOT}")
for rel in ("snap/local/assets/dashboard.html",):
    text = (repo / rel).read_text(encoding="utf-8")
    
    # Squash all newlines, tabs, and spaces into a single space to survive IDE auto-formatting
    flat_text = " ".join(text.split())

    assert 'class="report-action-grid"' in text, f"{rel} missing report action grid"
    assert 'id="report-vuln-summary"' in text, f"{rel} missing vulnerability report summary target"
    assert 'class="p-button--positive" href="vulnerabilities/"' in text, f"{rel} vulnerability report CTA is not visually distinct"
    assert 'class="channel-selector"' in text, f"{rel} channel selector missing dedicated class"
    assert '<h2 class="channel-selector__label">Channel scope</h2>' in text, f"{rel} channel selector missing h2 label"
    assert 'class="p-tabs"' in text, f"{rel} channel selector is not using Vanilla tabs"
    assert 'role="tablist"' in text, f"{rel} channel selector missing tablist role"
    
    # Check the flat_text for the long attribute strings that get wrapped by formatters
    assert 'id="btn-stable" type="button" role="tab" aria-selected="true"' in flat_text, f"{rel} stable channel is not a selected tab"
    assert 'id="btn-edge" type="button" role="tab" aria-selected="false"' in flat_text, f"{rel} edge channel is not an unselected tab"
PYEOF
}

@test "dashboard exposes channel switch release-health section and matrix table" {
    python3 - <<PYEOF
import pathlib
import sys

html_path = pathlib.Path("${REPO_ROOT}/snap/local/assets/dashboard.html")
assert html_path.exists()

text = html_path.read_text(encoding="utf-8")

# 1. Assert Release Health heading and Section ID exist
assert 'id="channel-switch-section"' in text, "Missing channel-switch-section"
assert 'Safe data migration' in text, "Missing Safe data migration label"
assert 'channel switch smoke test' in text, "Missing channel switch smoke test label"
assert 'channel switch smoke tests' not in text, "Channel switch label should be singular"
assert '<p class="p-heading--4">Store-channel refresh path' in text, "Missing p-heading--4 section description"
assert text.rfind('id="channel-switch-section"') > text.rfind('class="sync-tracking-table"'), "Channel switch section should be the last main-page section"
assert 'channel-switch-summary-grid' not in text, "Channel switch summary grid should be removed"

# 2. Assert table is present and has correct headers
assert 'id="channel-switch-details-table"' in text, "Missing channel-switch-details-table"
assert 'Test details' in text, "Missing Test details heading"
assert 'Architecture details' not in text, "Architecture details should be renamed"
assert '<th>Architecture</th>' in text, "Missing Architecture header"
assert '<th>Tested on</th>' in text, "Missing Tested on header"
assert '<th>Path</th>' in text, "Missing Path header"
assert '<th>Status</th>' in text, "Missing Status header"
assert '<th>Result</th>' not in text, "Result header should be renamed to Status"
assert '<th>Updated</th>' in text, "Missing Updated header"
assert '<th>Test duration</th>' in text, "Missing Test duration header"
assert '<th>Duration</th>' not in text, "Channel switch table duration header should be Test duration"
assert '<th>Details</th>' not in text, "Details should render as its own row, not a table column"
assert 'colspan="6">Loading details...' in text, "Loading row should span six summary columns"

# 3. Assert matrix body target exists
assert 'id="channel-switch-matrix-body"' in text, "Missing channel-switch-matrix-body"
assert 'id="channel-switch-timeline"' in text, "Missing channel-switch-timeline"
assert 'class="p-list-timeline"' in text, "Missing timeline list"
assert 'class="p-list-timeline__item"' in text, "Missing timeline item"
assert 'channel-switch-revision-chip' in text, "Missing channel revision chip markup"
assert 'channel-switch-revision-badge' in text, "Missing channel revision badge markup"
assert 'p-icon--chevron-right' in text, "Missing channel transition chevron icon"
assert 'channel-switch-details-row' in text, "Missing details row markup"
assert 'channel-switch-explanation--contained' in text, "Missing contained details explanation markup"
assert 'GitHub runner' in text, "Missing GitHub runner chip label"

# 4. Assert status chip text is not icon-only
assert 'id="channel-switch-status-chip"' not in text, "Standalone channel switch status chip should be removed"
assert '<span class="status-text-full" aria-hidden="true">' in text, "Missing status-text-full hidden span"
assert '<span class="status-text-short" aria-hidden="true">' in text, "Missing status-text-short hidden span"
PYEOF
}
