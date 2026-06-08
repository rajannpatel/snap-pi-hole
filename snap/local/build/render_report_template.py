#!/usr/bin/env python3
import pathlib
import sys

from report_assets import render_report_template


def main():
    if len(sys.argv) != 3:
        print("Usage: render_report_template.py SOURCE DESTINATION", file=sys.stderr)
        return 2

    source = pathlib.Path(sys.argv[1])
    destination = pathlib.Path(sys.argv[2])
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        render_report_template(source.read_text(encoding="utf-8")),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
