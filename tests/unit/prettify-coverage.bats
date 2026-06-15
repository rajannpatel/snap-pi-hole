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

@test "report templates render Vanilla CSS from the shared report asset config" {
    VANILLA_FRAMEWORK_VERSION="9.99.0" \
        python3 "${REPO_ROOT}/snap/local/build/render_report_template.py" \
        "${REPO_ROOT}/snap/local/assets/dashboard.html" \
        "${TMP_DIR}/dashboard.html"

    grep -q "vanilla_framework_version_9.99.0.min.css" "${TMP_DIR}/dashboard.html"
    ! grep -q "VANILLA_FRAMEWORK_CSS" "${TMP_DIR}/dashboard.html"
}

@test "prettify_coverage.py replaces stale Vanilla CSS links with the shared report asset config" {
    sed -i '/<\/head>/i\  <link rel="stylesheet" href="https://assets.ubuntu.com/v1/vanilla_framework_version_1.2.3.min.css" />' "${TMP_DIR}/index.html"

    VANILLA_FRAMEWORK_VERSION="9.99.0" \
        python3 "${REPO_ROOT}/snap/local/build/prettify_coverage.py" "${TMP_DIR}"

    grep -q "vanilla_framework_version_9.99.0.min.css" "${TMP_DIR}/index.html"
    ! grep -q "vanilla_framework_version_1.2.3.min.css" "${TMP_DIR}/index.html"
}

@test "Vanilla Framework CDN version is not duplicated outside the shared report asset helper" {
    run bash -c "rg -n 'vanilla_framework_version_[0-9]' '${REPO_ROOT}/snap/local/assets' '${REPO_ROOT}/snap/local/build' '${REPO_ROOT}/.github' '${REPO_ROOT}/tests/scripts' | grep -v 'snap/local/build/report_assets.py'"
    [ "$status" -ne 0 ]
}

@test "sbom-explorer.html layout and styling requirements (non-blocking warning)" {
    # 1. Assert sbom-explorer.html contains the semantic <time id="meta-time"> tag
    assert_warn "grep -q 'time id=\"meta-time\"' '${REPO_ROOT}/snap/local/assets/sbom-explorer.html'" "sbom-explorer.html is missing semantic <time> tag"
    assert_warn "grep -q '<main>' '${REPO_ROOT}/snap/local/assets/sbom-explorer.html'" "sbom-explorer.html is missing semantic main landmark"
    assert_warn "grep -q '<caption class=\"u-off-screen\">' '${REPO_ROOT}/snap/local/assets/sbom-explorer.html'" "sbom-explorer.html is missing accessible table caption"
    assert_warn "grep -q 'aria-pressed=\"true\"' '${REPO_ROOT}/snap/local/assets/sbom-explorer.html'" "sbom-explorer.html architecture selector is missing pressed state"
    
    # 2. Assert sbom-explorer stylesheet contains unified footer background color (#2d2d2d)
    assert_warn "grep -q 'background-color: #2d2d2d' '${REPO_ROOT}/snap/local/assets/sbom-explorer.css'" "sbom-explorer.css is missing unified dark footer background (#2d2d2d)"
    
    # 3. Assert sbom-explorer stylesheet contains custom link color (rgb(102, 153, 204))
    assert_warn "grep -q 'color: rgb(102, 153, 204)' '${REPO_ROOT}/snap/local/assets/sbom-explorer.css'" "sbom-explorer.css is missing custom link color rgb(102, 153, 204)"
    
    # 4. Assert sbom-explorer stylesheet contains hover transition to Ubuntu Orange (#e95420)
    assert_warn "grep -q 'color: #e95420' '${REPO_ROOT}/snap/local/assets/sbom-explorer.css'" "sbom-explorer.css is missing hover color transition to Ubuntu Orange (#e95420)"
    
    # 5. Assert sbom-explorer.html contains License column wrapping rule and space joiner
    assert_warn "grep -q 'td:nth-child(4)' '${REPO_ROOT}/snap/local/assets/sbom-explorer.css'" "sbom-explorer.css is missing License column CSS wrapping rule"
    assert_warn "grep -q \"join(' ')\" '${REPO_ROOT}/snap/local/assets/sbom-explorer.html'" "sbom-explorer.html is missing license chip space joiner"
}

@test "dashboard.html layout and styling requirements (non-blocking warning)" {
    # 1. Assert dashboard.html uses Vanilla typography source and breadcrumb overrides
    assert_warn "! grep -q 'fonts.googleapis.com' '${REPO_ROOT}/snap/local/assets/dashboard.html'" "dashboard.html should not import Google Fonts"
    assert_warn "grep -q 'letter-spacing: normal' '${REPO_ROOT}/snap/local/assets/dashboard.css'" "dashboard.css is missing breadcrumb letter-spacing override"
    
    # 3. Assert dashboard.html has breadcrumbs element
    assert_warn "grep -q 'p-breadcrumbs' '${REPO_ROOT}/snap/local/assets/dashboard.html'" "dashboard.html is missing Vanilla Framework breadcrumbs"
    assert_warn "grep -q '<main>' '${REPO_ROOT}/snap/local/assets/dashboard.html'" "dashboard.html is missing semantic main landmark"
    assert_warn "grep -q '<article class=\"p-card\"' '${REPO_ROOT}/snap/local/assets/dashboard.html'" "dashboard.html is missing semantic report cards"
    assert_warn "grep -q 'class=\"p-button\" href=\"sbom/\"' '${REPO_ROOT}/snap/local/assets/dashboard.html'" "dashboard.html SBOM button is not using the default button style"
    assert_warn "grep -q 'href=\"vulnerabilities/\"' '${REPO_ROOT}/snap/local/assets/dashboard.html'" "dashboard.html is missing vulnerability reports link"
    
    # 4. Assert dashboard stylesheet contains unified footer background color (#2d2d2d)
    assert_warn "grep -q 'background-color: #2d2d2d' '${REPO_ROOT}/snap/local/assets/dashboard.css'" "dashboard.css is missing unified dark footer background (#2d2d2d)"
    
    # 5. Assert dashboard stylesheet contains custom link color (rgb(102, 153, 204))
    assert_warn "grep -q 'color: rgb(102, 153, 204)' '${REPO_ROOT}/snap/local/assets/dashboard.css'" "dashboard.css is missing custom link color rgb(102, 153, 204)"
    
    # 6. Assert dashboard stylesheet contains hover transition to Ubuntu Orange (#e95420)
    assert_warn "grep -q 'color: #e95420' '${REPO_ROOT}/snap/local/assets/dashboard.css'" "dashboard.css is missing hover color transition to Ubuntu Orange (#e95420)"
}
