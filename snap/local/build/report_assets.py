import os
import re


VANILLA_FRAMEWORK_VERSION = os.environ.get("VANILLA_FRAMEWORK_VERSION", "4.51.0")
VANILLA_FRAMEWORK_CSS_URL = os.environ.get(
    "VANILLA_FRAMEWORK_CSS_URL",
    f"https://assets.ubuntu.com/v1/vanilla_framework_version_{VANILLA_FRAMEWORK_VERSION}.min.css",
)
VANILLA_FRAMEWORK_CSS_TOKEN = "<!-- VANILLA_FRAMEWORK_CSS -->"
VANILLA_FRAMEWORK_LINK_RE = re.compile(
    r'^[ \t]*<link rel="stylesheet" href="https://assets\.ubuntu\.com/v1/'
    r'vanilla_framework_version_[^"]+\.min\.css" />\n?',
    re.MULTILINE,
)


def vanilla_framework_css_link(indent=2):
    return (
        f'{" " * indent}<link rel="stylesheet" '
        f'href="{VANILLA_FRAMEWORK_CSS_URL}" />'
    )


def inject_vanilla_framework_css(content):
    content = VANILLA_FRAMEWORK_LINK_RE.sub("", content)
    return content.replace("</head>", f"{vanilla_framework_css_link()}\n</head>", 1)


def render_report_template(content):
    return content.replace(VANILLA_FRAMEWORK_CSS_TOKEN, vanilla_framework_css_link(indent=0))
