#!/usr/bin/env python3
import argparse
import os
import pathlib
import re
import subprocess
import sys
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from resolve_upstream_version import latest_release_versions


GITHUB_API = "https://api.github.com"
UPSTREAM_STABLE_REF = "master"
UPSTREAM_EDGE_REF = "development"
COMPONENTS = {
    "ftl": "pi-hole/FTL",
    "pi_hole": "pi-hole/pi-hole",
    "web": "pi-hole/web",
}


def github_json(url, token=""):
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "snap-pi-hole-upstream-selector",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def git_remote_ref(repo, ref):
    output = subprocess.check_output(
        ["git", "ls-remote", f"https://github.com/{repo}.git", f"refs/heads/{ref}"],
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()
    if not output:
        raise RuntimeError(f"Could not resolve {repo}@{ref}")
    return output.split()[0]


def upstream_ref_versions(ref, token=""):
    versions = {}
    for key, repo in COMPONENTS.items():
        try:
            data = github_json(f"{GITHUB_API}/repos/{repo}/commits/{ref}", token=token)
            versions[key] = data["sha"]
        except Exception:
            versions[key] = git_remote_ref(repo, ref)
    return versions


def update_source_commits(snapcraft_path, versions):
    current_part = None
    changed = set()
    lines = []
    for raw in snapcraft_path.read_text(encoding="utf-8").splitlines():
        part_match = re.match(r"^  ([A-Za-z0-9_]+):\s*$", raw)
        if part_match:
            candidate = part_match.group(1)
            current_part = candidate if candidate in versions else None
            lines.append(raw)
            continue

        if current_part and re.match(r"^    source-(tag|commit|branch):\s*\S+\s*$", raw):
            lines.append(f"    source-commit: \"{versions[current_part]}\"")
            changed.add(current_part)
            continue

        lines.append(raw)

    missing = sorted(set(versions) - changed)
    if missing:
        raise RuntimeError(f"Missing source-tag/source-commit/source-branch entries for: {', '.join(missing)}")

    snapcraft_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Select upstream Pi-hole sources for snapcraft builds.")
    parser.add_argument("channel", choices=["stable", "edge"])
    parser.add_argument("--snapcraft", default="snap/snapcraft.yaml")
    args = parser.parse_args()

    snapcraft_path = pathlib.Path(args.snapcraft)
    token = os.environ.get("GITHUB_TOKEN", "")
    stable_versions = latest_release_versions(token=token)

    ref = UPSTREAM_STABLE_REF if args.channel == "stable" else UPSTREAM_EDGE_REF
    versions = upstream_ref_versions(ref, token=token)
    update_source_commits(snapcraft_path, versions)
    print(f"Selected upstream {ref} commits for {args.channel} builds:")
    for key in ("ftl", "pi_hole", "web"):
        print(f"  {key}: {versions[key]} ({stable_versions[key]})")


if __name__ == "__main__":
    main()
