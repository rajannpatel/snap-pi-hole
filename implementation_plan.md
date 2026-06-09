# Enhance Vulnerability Reports with LLM-powered Confinement Analysis

This plan outlines the design and implementation steps to itemize all CVEs in the vulnerabilities table, analyze why snap confinement mitigations are (or are not) appropriate for each CVE using an LLM (GitHub Models), update the HTML and Markdown tables/reports, and configure the GitHub Actions workflow.

## User Review Required

> [!NOTE]
> We will add a local cache file `local-vulnerabilities/llm-cache.json` to store the generated explanations. This ensures that:
> 1. We don't make redundant API calls to the LLM during local testing or routine CI runs.
> 2. The script works reliably (falling back to cache) even when `LLM_API_KEY` is not present in the environment (e.g., local preview runs or external forks).
> 3. New CVEs discovered during a scan will trigger a live API call in CI (when `LLM_API_KEY` is provided) and automatically log the responses, ready to be cached.

## Open Questions

None at this stage. The requirements are fully detailed, and the proposed design covers all bases.

## Proposed Changes

---

### Component: CI/CD Workflows

#### [MODIFY] [.github/workflows/cicd.yml](file:///home/rajan/Projects/snaps/pihole/.github/workflows/cicd.yml)
- Pass the `LLM_API_KEY` secret as an environment variable to the step in the `vulnerability-scan` job that runs `summarize_osv_reports.py`.

---

### Component: Vulnerability Report Script & Cache

#### [NEW] [llm-cache.json](file:///home/rajan/Projects/snaps/pihole/local-vulnerabilities/llm-cache.json)
- Create a persistent JSON cache containing pre-computed LLM analysis for existing CVEs (`CVE-2023-38545` and the mock `CVE-2023-99999`).

#### [MODIFY] [summarize_osv_reports.py](file:///home/rajan/Projects/snaps/pihole/snap/local/build/summarize_osv_reports.py)
- Load/save the JSON cache from/to `local-vulnerabilities/llm-cache.json`.
- Implement a helper to query the LLM API (GitHub Models) via `urllib` to fetch explanations for any uncached CVE.
- Update `write_html` to output a multi-column spanning row (`<tr class="vulnerability-explanation-row">`) under each vulnerability row.
- Update the HTML design of the table to display explanations in a styled grid box.
- Update table filtering and sorting Javascript logic to ensure that explanation rows stay paired with their parent rows.
- Update `write_markdown` to append a "Confinement Analysis" section itemizing each CVE and its explanations.

## Verification Plan

### Automated Tests
- Run BATS unit tests:
  ```bash
  bats tests/unit/security-reports.bats
  ```
- We will update the mock test data in `tests/unit/security-reports.bats` if needed to ensure it works correctly with the new structure.

### Manual Verification
- Run the local preview script to generate reports locally and verify HTML rendering:
  ```bash
  tests/scripts/local-preview.sh
  ```
- Use the browser tool to inspect the generated HTML page and verify that:
  1. The layout is correct and matches Vanilla Framework guidelines.
  2. Sorting and filtering still work flawlessly, keeping parent and explanation rows grouped.
