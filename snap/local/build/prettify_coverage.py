import os
import sys
import re

def prettify_file(filepath, is_root):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    # 1. Inject Google Fonts and Vanilla Framework CSS links into <head>
    fonts_links = (
        '  <link rel="preconnect" href="https://fonts.googleapis.com">\n'
        '  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n'
        '  <link href="https://fonts.googleapis.com/css2?family=Ubuntu:ital,wght@0,300;0,400;0,500;0,700;1,300;1,400;1,500;1,700&family=Ubuntu+Mono:ital,wght@0,400;0,700;1,400;1,700&display=swap" rel="stylesheet">'
    )
    vanilla_css = '  <link rel="stylesheet" href="https://assets.ubuntu.com/v1/vanilla_framework_version_4.51.0.min.css" />'
    if 'fonts.googleapis.com' not in content:
        content = content.replace('</head>', f'{fonts_links}\n</head>')
    if vanilla_css not in content:
        content = content.replace('</head>', f'{vanilla_css}\n</head>')

    # 2. Extract kcov's handlebars template and placeholder
    template_match = re.search(r'(<script id="(?:files|lines)-template".*?</script>)', content, re.DOTALL | re.IGNORECASE)
    placeholder_match = re.search(r'(<div id="(?:files|lines)-placeholder"></div>)', content, re.DOTALL | re.IGNORECASE)

    if not template_match or not placeholder_match:
        return

    template_html = template_match.group(1)
    placeholder_html = placeholder_match.group(1)

    # Clean up center/width tags inside template HTML to let Vanilla CSS handle table layout
    template_html = template_html.replace('<center>', '').replace('</center>', '')
    template_html = re.sub(r'width="\d+%"', '', template_html)
    template_html = re.sub(r'cellpadding="\d+"', '', template_html)
    template_html = re.sub(r'cellspacing="\d+"', '', template_html)
    template_html = re.sub(r'border="\d+"', '', template_html)
    template_html = template_html.replace('<source-line>', '<source-line class="{{class}}">')
    header_row_html = (
        '<div class="source-header-row">'
        '<span class="source-header-label line-num-header">Line</span>'
        '<span class="source-header-label hits-header">Hits</span>'
        '<span class="source-header-label code-header">Source Code</span>'
        '<span class="source-header-label order-header">Order</span>'
        '</div>'
    )
    template_html = re.sub(r'(<pre class="source"[^>]*>)', rf'<div class="source-wrapper">\1{header_row_html}', template_html).replace('</pre>', '</pre></div>')
    template_html = template_html.replace('id="index-table"', 'id="index-table-no-sort"')

    # Determine paths based on depth
    home_href = 'index.html' if is_root else '../index.html'
    logo_src = 'pihole.png' if is_root else '../pihole.png'
    sbom_href = '../sbom/' if is_root else '../../sbom/'
    coverage_href = 'index.html' if is_root else '../index.html'

    if is_root:
        dashboard_href = '../'
        breadcrumbs_html = f"""
          <nav class="p-breadcrumbs" aria-label="Breadcrumbs" style="margin-bottom: 1.5rem;">
            <ol class="p-breadcrumbs__items">
              <li class="p-breadcrumbs__item">
                <a href="{dashboard_href}">Reports Dashboard</a>
              </li>
              <li class="p-breadcrumbs__item">
                Coverage Report
              </li>
            </ol>
          </nav>
"""
    else:
        dashboard_href = '../../'
        base = os.path.basename(filepath)
        if base == 'index.html':
            parent_dir = os.path.basename(os.path.dirname(filepath))
            if parent_dir.startswith('bats'):
                detail_name = 'BATS Test Suite'
            else:
                detail_name = parent_dir
        else:
            detail_name = re.sub(r'\.[a-f0-9]{8}\.html$', '', base)
            detail_name = re.sub(r'\.html$', '', detail_name)

        breadcrumbs_html = f"""
          <nav class="p-breadcrumbs" aria-label="Breadcrumbs" style="margin-bottom: 1.5rem;">
            <ol class="p-breadcrumbs__items">
              <li class="p-breadcrumbs__item">
                <a href="{dashboard_href}">Reports Dashboard</a>
              </li>
              <li class="p-breadcrumbs__item">
                <a href="../index.html">Coverage Report</a>
              </li>
              <li class="p-breadcrumbs__item">
                {detail_name}
              </li>
            </ol>
          </nav>
"""

    footer_html = f"""
    <!-- Footer -->
    <footer class="p-strip--dark" style="padding-top: 2rem !important; padding-bottom: 2rem !important; margin-top: 3rem;">
      <div class="row">
        <div class="col-4">
          <h5>Project Resources</h5>
          <ul class="p-list">
            <li><a href="https://github.com/rajannpatel/snap-pi-hole" class="is-dark">GitHub Repository</a></li>
            <li><a href="https://github.com/rajannpatel/snap-pi-hole/wiki" class="is-dark">Project Wiki Documentation</a></li>
            <li><a href="https://snapcraft.io/pihole-by-rajannpatel" class="is-dark">Snap Store Listing</a></li>
          </ul>
        </div>
        <div class="col-4">
          <h5>CI/CD Pipeline</h5>
          <ul class="p-list">
            <li><a href="https://github.com/rajannpatel/snap-pi-hole/actions" class="is-dark">Workflow Execution History</a></li>
            <li><a href="https://github.com/rajannpatel/snap-pi-hole/actions/workflows/cicd.yml" class="is-dark">Pipeline Definition (YAML)</a></li>
            <li><a href="{sbom_href}" class="is-dark">Software Bill of Materials (SBOM)</a></li>
            <li><a href="{coverage_href}" class="is-dark">Code Coverage Reports</a></li>
          </ul>
        </div>
        <div class="col-4">
          <h5>Security & Confinement</h5>
          <p class="p-text--small">
            Built securely on Ubuntu builders. Packaged as a strictly confined Snap, ensuring isolated execution and sandboxed system interactions for Pi-hole Core services.
          </p>
      </div>
    </footer>
"""

    is_detail_page = '<pre class="source"' in content
    if is_detail_page:
        explanations_html = """
          <!-- Terminology Explanations -->
          <div style="background-color: #f7f7f7; border: 1px solid #dbdbdb; border-radius: 4px; padding: 1rem; margin-bottom: 1.5rem; font-size: 0.875rem; color: #666666; line-height: 1.4;">
            <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 1rem;">
              <div>
                <strong style="color: #111111; font-weight: 500; display: block; margin-bottom: 2px;">Instrumented Lines</strong>
                The total lines of code that are executable and monitored for coverage.
              </div>
              <div>
                <strong style="color: #111111; font-weight: 500; display: block; margin-bottom: 2px;">Executed Lines</strong>
                The number of instrumented lines that were run at least once during tests.
              </div>
              <div>
                <strong style="color: #111111; font-weight: 500; display: block; margin-bottom: 2px;">Hits</strong>
                The exact number of times a specific line of code was executed.
              </div>
              <div>
                <strong style="color: #111111; font-weight: 500; display: block; margin-bottom: 2px;">Order</strong>
                The sequence index indicating when a line was executed relative to others.
              </div>
            </div>
          </div>
"""
    else:
        explanations_html = ""

    new_body = f"""
  <div class="l-site">
    <!-- Navigation Header -->
    <header class="p-navigation is-dark" style="margin-bottom: 0 !important; border-bottom: none !important;">
      <div class="p-navigation__row" style="padding: 0 1.5rem !important;">
        <div class="p-navigation__banner" style="margin: 0 !important; height: 56px !important; display: flex !important; align-items: center !important;">
          <a class="p-navigation__link" href="{home_href}" style="display: flex; align-items: center; text-decoration: none; gap: 12px; padding: 0; margin: 0; line-height: 1;">
            <img src="{logo_src}" alt="Pi-hole Logo" style="height: 32px; width: 32px; display: block;">
          </a>
        </div>
      </div>
    </header>

    <!-- Main Content Strip -->
    <main class="p-strip" style="background-color: #ffffff; flex-grow: 1; padding-top: 2rem !important; padding-bottom: 2rem !important;">
      <div class="row">
        <div class="col-12">
          {breadcrumbs_html}
          
          <!-- Semantic Header -->
          <div class="row" style="margin-bottom: 2rem;">
            <div class="col-12">
              <h1 class="p-heading--2" style="margin-bottom: 1.5rem;">Coverage Report</h1>
              <div class="row">
                <div class="col-4">
                  <div class="p-card">
                    <span class="p-text--small-muted">COMMAND</span>
                    <h4 class="p-card__title" id="header-command" style="font-family: monospace;">???</h4>
                  </div>
                </div>
                <div class="col-4">
                  <div class="p-card">
                    <span class="p-text--small-muted">GENERATION TIME</span>
                    <h4 class="p-card__title"><time id="header-date"></time></h4>
                  </div>
                </div>
              </div>
            </div>
          </div>
          <hr class="is-muted" style="margin: 1.5rem 0;">

          <!-- Data Spotlight Statistics -->
          <div class="row p-equal-height-row--wrap u-sv3" style="margin-bottom: 2rem;">
            <div class="col-4 p-equal-height-row__col u-no-margin--bottom p-data-spotlight__block">
              <div class="p-equal-height-row__item">
                <hr class="p-rule--highlight" style="margin: 0 0 1rem 0 !important;">
                <p class="p-heading--1 u-no-margin u-no-padding"><span id="header-percent-covered">???</span></p>
              </div>
              <p class="p-equal-height-row__item p-heading--3 u-no-margin u-no-padding" style="margin-top: 0.5rem !important;">Code Covered</p>
            </div>
            <div class="col-4 p-equal-height-row__col u-no-margin--bottom p-data-spotlight__block">
              <div class="p-equal-height-row__item">
                <hr class="p-rule--highlight" style="margin: 0 0 1rem 0 !important;">
                <p class="p-heading--1 u-no-margin u-no-padding"><span id="header-instrumented">???</span></p>
              </div>
              <p class="p-equal-height-row__item p-heading--3 u-no-margin u-no-padding" style="margin-top: 0.5rem !important;">Instrumented Lines</p>
            </div>
            <div class="col-4 p-equal-height-row__col u-no-margin--bottom p-data-spotlight__block">
              <div class="p-equal-height-row__item">
                <hr class="p-rule--highlight" style="margin: 0 0 1rem 0 !important;">
                <p class="p-heading--1 u-no-margin u-no-padding"><span id="header-covered">???</span></p>
              </div>
              <p class="p-equal-height-row__item p-heading--3 u-no-margin u-no-padding" style="margin-top: 0.5rem !important;">Executed Lines</p>
            </div>
          </div>
          <hr class="is-muted" style="margin: 1.5rem 0;">
          {explanations_html}

          <!-- Main Coverage Data -->
          {template_html}
          {placeholder_html}

        </div>
      </div>
    </main>

    {footer_html}
  </div>
  <script>
    // Ensure the <time> elements are fully compliant with datetime attribute
    (function() {{
      function updateDatetime() {{
        var dateEl = document.getElementById('header-date');
        if (dateEl && dateEl.innerHTML && dateEl.innerHTML.trim() !== 'N/A') {{
          var dt = dateEl.innerHTML.trim().replace(' ', 'T');
          dateEl.setAttribute('datetime', dt);
          return true;
        }}
        return false;
      }}

      // Try immediately if already populated
      if (!updateDatetime()) {{
        // Fall back to wrapping window.onload
        var oldOnload = window.onload;
        window.onload = function() {{
          if (oldOnload) {{
            oldOnload();
          }}
          updateDatetime();
        }};
      }}
    }})();
  </script>
"""

    # Replace <body> tag content
    content = re.sub(r'<body>.*</body>', f'<body>{new_body}</body>', content, flags=re.DOTALL | re.IGNORECASE)

    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(content)

def main():
    coverage_dir = sys.argv[1] if len(sys.argv) > 1 else 'local-coverage'
    if not os.path.exists(coverage_dir):
        print(f"Error: Coverage directory {coverage_dir} does not exist.")
        sys.exit(1)

    for root, dirs, files in os.walk(coverage_dir):
        for file in files:
            if file.endswith('.html'):
                filepath = os.path.join(root, file)
                # Check if it is the root index.html or in a subdirectory
                is_root = (root == coverage_dir)
                prettify_file(filepath, is_root)
                print(f"Prettified: {filepath}")

if __name__ == '__main__':
    main()
