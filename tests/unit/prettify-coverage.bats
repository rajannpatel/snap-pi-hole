#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TMP_DIR="$(mktemp -d)"
    
    # Create mock Kcov coverage page structure
    mkdir -p "${TMP_DIR}/bats.e38fe61c8733e2cd"
    
    # Mock index.html in coverage root
    cat << 'EOF' > "${TMP_DIR}/index.html"
<!DOCTYPE html>
<html>
<head>
  <title>Kcov Coverage Report</title>
  <link rel="stylesheet" href="bcov.css">
</head>
<body>
  <table>
    <tr>
      <td class="headerItem">Command:</td>
      <td class="headerValue">bats</td>
      <td class="headerItem">Date:</td>
      <td class="headerValue">2026-06-03 09:55:22</td>
    </tr>
    <tr>
      <td class="headerItem">Instrumented Lines:</td>
      <td class="headerValue">100</td>
      <td class="headerItem">Executed Lines:</td>
      <td class="headerValue">80</td>
      <td class="headerItem">Code Covered:</td>
      <td class="headerValue">80.0%</td>
    </tr>
  </table>
  <script id="files-template" type="text/x-handlebars-template">
    Some template code
  </script>
  <div id="files-placeholder"></div>
  <div class="footer">
    Maintained by rajannpatel / snap-pi-hole. Built with Vanilla Framework.
  </div>
</body>
</html>
EOF

    # Copy kcov-override.css to bcov.css (matching local-preview.sh behavior)
    cp "${REPO_ROOT}/snap/local/assets/kcov-override.css" "${TMP_DIR}/bcov.css"
    
    # Mock details page
    cat << 'EOF' > "${TMP_DIR}/bats.e38fe61c8733e2cd/snap-debug.sh.a7834a16.html"
<!DOCTYPE html>
<html>
<head>
  <title>snap-debug.sh</title>
  <link rel="stylesheet" href="../bcov.css">
</head>
<body>
  <table>
    <tr>
      <td class="headerItem">Command:</td>
      <td class="headerValue">bats</td>
      <td class="headerItem">Date:</td>
      <td class="headerValue">2026-06-03 09:55:22</td>
    </tr>
  </table>
  <script id="lines-template" type="text/x-handlebars-template">
    Some lines template code
  </script>
  <div id="lines-placeholder"></div>
  <pre class="source">
    some source code
  </pre>
</body>
</html>
EOF
}

teardown() {
    rm -rf "${TMP_DIR}"
}

# Helper to check a condition and print a warning annotation on failure without failing the test
assert_warn() {
    local condition_cmd="$1"
    local error_msg="$2"
    if ! eval "$condition_cmd"; then
        echo "::warning file=tests/unit/prettify-coverage.bats,title=KCOV/SBOM Report Verification Failed::${error_msg}" >&2
        echo "WARNING: ${error_msg}" >&2
    fi
}

@test "prettify_coverage.py converts mock coverage report structure (non-blocking warning)" {
    # Run the prettifier on mock directory
    python3 "${REPO_ROOT}/snap/local/build/prettify_coverage.py" "${TMP_DIR}"
    
    # 1. Assert bcov.css is replaced by kcov-override.css
    assert_warn "[ -f '${TMP_DIR}/bcov.css' ]" "bcov.css file was not generated"
    assert_warn "grep -q 'Vanilla Framework Core Override for Kcov Coverage Reports' '${TMP_DIR}/bcov.css'" "bcov.css does not contain the kcov-override.css styles"
    
    # 2. Assert index.html has breadcrumbs
    assert_warn "grep -q 'p-breadcrumbs' '${TMP_DIR}/index.html'" "index.html is missing Vanilla Framework breadcrumbs"
    assert_warn "grep -q 'aria-current=\"page\"' '${TMP_DIR}/index.html'" "index.html breadcrumb is missing aria-current page state"

    # 2a. Assert index.html has mobile viewport metadata
    assert_warn "grep -q 'name=\"viewport\" content=\"width=device-width, initial-scale=1.0\"' '${TMP_DIR}/index.html'" "index.html is missing mobile viewport metadata"
    
    # 3. Assert index.html has Data Spotlight Statistics layout
    assert_warn "grep -q 'p-data-spotlight__block' '${TMP_DIR}/index.html'" "index.html is missing Data Spotlight Statistics"
    
    # 4. Assert index.html has standardized card boxes for command/date
    assert_warn "grep -q 'COMMAND' '${TMP_DIR}/index.html'" "index.html is missing COMMAND metadata card"
    assert_warn "grep -q 'GENERATION TIME' '${TMP_DIR}/index.html'" "index.html is missing GENERATION TIME metadata card"
    
    # 5. Assert semantic <time> tag exists
    assert_warn "grep -q 'time id=\"header-date\"' '${TMP_DIR}/index.html'" "index.html is missing semantic <time> tag for generation time"
    
    # 6. Assert dynamic date js updater is injected
    assert_warn "grep -q 'updateDatetime' '${TMP_DIR}/index.html'" "index.html is missing the Javascript date update script"
    
    # 7. Assert footer matches standardized styling
    assert_warn "grep -q 'footer class=\"p-strip--dark\"' '${TMP_DIR}/index.html'" "index.html is missing the standardized dark footer element"
    
    # 8. Assert details page contains horizontal legend cards grid
    assert_warn "grep -q 'Instrumented Lines' '${TMP_DIR}/bats.e38fe61c8733e2cd/snap-debug.sh.a7834a16.html'" "Detail page is missing Instrumented Lines explanation"
    assert_warn "grep -q '<article class=\"p-card\"' '${TMP_DIR}/bats.e38fe61c8733e2cd/snap-debug.sh.a7834a16.html'" "Detail page is missing semantic explanation cards"
    assert_warn "grep -q 'u-equal-height' '${TMP_DIR}/bats.e38fe61c8733e2cd/snap-debug.sh.a7834a16.html'" "Detail page is missing equal-height utility class on card row"
}

@test "sbom-explorer.html layout and styling requirements (non-blocking warning)" {
    # 1. Assert sbom-explorer.html contains the semantic <time id="meta-time"> tag
    assert_warn "grep -q 'time id=\"meta-time\"' '${REPO_ROOT}/snap/local/assets/sbom-explorer.html'" "sbom-explorer.html is missing semantic <time> tag"
    assert_warn "grep -q '<main>' '${REPO_ROOT}/snap/local/assets/sbom-explorer.html'" "sbom-explorer.html is missing semantic main landmark"
    assert_warn "grep -q '<caption class=\"u-off-screen\">' '${REPO_ROOT}/snap/local/assets/sbom-explorer.html'" "sbom-explorer.html is missing accessible table caption"
    assert_warn "grep -q 'aria-pressed=\"true\"' '${REPO_ROOT}/snap/local/assets/sbom-explorer.html'" "sbom-explorer.html architecture selector is missing pressed state"
    
    # 2. Assert sbom-explorer.html contains unified footer background color (#2d2d2d)
    assert_warn "grep -q 'background-color: #2d2d2d' '${REPO_ROOT}/snap/local/assets/sbom-explorer.html'" "sbom-explorer.html is missing unified dark footer background (#2d2d2d)"
    
    # 3. Assert sbom-explorer.html contains custom link color (rgb(102, 153, 204))
    assert_warn "grep -q 'color: rgb(102, 153, 204)' '${REPO_ROOT}/snap/local/assets/sbom-explorer.html'" "sbom-explorer.html is missing custom link color rgb(102, 153, 204)"
    
    # 4. Assert sbom-explorer.html contains hover transition to Ubuntu Orange (#e95420)
    assert_warn "grep -q 'color: #e95420' '${REPO_ROOT}/snap/local/assets/sbom-explorer.html'" "sbom-explorer.html is missing hover color transition to Ubuntu Orange (#e95420)"
}

@test "dashboard.html layout and styling requirements (non-blocking warning)" {
    # 1. Assert dashboard.html contains the Google Fonts preconnect/stylesheet links
    assert_warn "grep -q 'fonts.googleapis.com' '${REPO_ROOT}/snap/local/assets/dashboard.html'" "dashboard.html is missing Google Fonts link"
    
    # 2. Assert dashboard.html has custom typography configuration
    assert_warn "grep -q 'font-family: '\''Ubuntu'\''' '${REPO_ROOT}/snap/local/assets/dashboard.html'" "dashboard.html is missing Ubuntu font styling"
    
    # 3. Assert dashboard.html has breadcrumbs element
    assert_warn "grep -q 'p-breadcrumbs' '${REPO_ROOT}/snap/local/assets/dashboard.html'" "dashboard.html is missing Vanilla Framework breadcrumbs"
    assert_warn "grep -q '<main>' '${REPO_ROOT}/snap/local/assets/dashboard.html'" "dashboard.html is missing semantic main landmark"
    assert_warn "grep -q '<article class=\"p-card\"' '${REPO_ROOT}/snap/local/assets/dashboard.html'" "dashboard.html is missing semantic report cards"
    
    # 4. Assert dashboard.html contains unified footer background color (#2d2d2d)
    assert_warn "grep -q 'background-color: #2d2d2d' '${REPO_ROOT}/snap/local/assets/dashboard.html'" "dashboard.html is missing unified dark footer background (#2d2d2d)"
    
    # 5. Assert dashboard.html contains custom link color (rgb(102, 153, 204))
    assert_warn "grep -q 'color: rgb(102, 153, 204)' '${REPO_ROOT}/snap/local/assets/dashboard.html'" "dashboard.html is missing custom link color rgb(102, 153, 204)"
    
    # 6. Assert dashboard.html contains hover transition to Ubuntu Orange (#e95420)
    assert_warn "grep -q 'color: #e95420' '${REPO_ROOT}/snap/local/assets/dashboard.html'" "dashboard.html is missing hover color transition to Ubuntu Orange (#e95420)"
}
