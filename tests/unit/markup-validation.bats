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

@test "sbom-explorer.html has balanced block markup" {
    run check_balance "${REPO_ROOT}/snap/local/assets/sbom-explorer.html"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
