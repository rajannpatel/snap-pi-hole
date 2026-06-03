import os
import sys
import re

def prettify_file(filepath, is_root):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    # 1. Inject Vanilla Framework CSS link into <head>
    vanilla_css = '<link rel="stylesheet" href="https://assets.ubuntu.com/v1/vanilla_framework_version_4.51.0.min.css" />'
    if vanilla_css not in content:
        content = content.replace('</head>', f'  {vanilla_css}\n</head>')

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
      </div>
      <div class="row u-sv2">
        <div class="col-12">
          <hr class="is-dark">
          <p class="u-align--center p-text--small-muted" style="margin-bottom: 0;">
            Maintained by <a href="https://github.com/rajannpatel" class="is-dark">rajannpatel</a> / <a href="https://github.com/rajannpatel/snap-pi-hole" class="is-dark">snap-pi-hole</a>. Built with <a href="https://vanillaframework.io/" class="is-dark">Vanilla Framework</a>.
          </p>
        </div>
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
          
          <!-- Semantic Header -->
          <div class="row" style="margin-bottom: 2rem;">
            <div class="col-6">
              <h1 class="p-heading--2" style="margin-bottom: 1.5rem;">Coverage Report</h1>
              <div style="display: grid; grid-template-columns: auto 1fr; gap: 0.5rem 1.5rem; align-items: baseline; font-size: 0.875rem;">
                <span style="font-weight: 500; color: #666666;">Command:</span>
                <span id="header-command" style="font-family: monospace;">???</span>
                
                <span style="font-weight: 500; color: #666666;">Date:</span>
                <span id="header-date"></span>
                
                <span style="font-weight: 500; color: #666666;">Code covered:</span>
                <span id="header-percent-covered" style="font-weight: 500; padding: 2px 6px; border-radius: 4px; display: inline-block; width: fit-content;">???</span>
              </div>
            </div>
            <div class="col-6 u-align--right" style="display: flex; flex-direction: column; justify-content: flex-end; align-items: flex-end; gap: 0.75rem;">
              <div style="display: grid; grid-template-columns: auto auto; gap: 0.5rem 1rem; font-size: 0.875rem; text-align: right;">
                <span style="color: #666666;">Instrumented lines:</span>
                <strong id="header-instrumented">???</strong>
                
                <span style="color: #666666;">Executed lines:</span>
                <strong id="header-covered">???</strong>
              </div>
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
