#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import re
import subprocess
import urllib.request


GITHUB_API = "https://api.github.com"
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


def upstream_dev_versions(token=""):
    versions = {}
    for key, repo in COMPONENTS.items():
        try:
            data = github_json(f"{GITHUB_API}/repos/{repo}/commits/{UPSTREAM_EDGE_REF}", token=token)
            versions[key] = data["sha"]
        except Exception:
            versions[key] = git_remote_ref(repo, UPSTREAM_EDGE_REF)
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

        if current_part and re.match(r"^    source-(tag|commit):\s*\S+\s*$", raw):
            lines.append(f"    source-commit: {versions[current_part]}")
            changed.add(current_part)
            continue

        lines.append(raw)

    missing = sorted(set(versions) - changed)
    if missing:
        raise RuntimeError(f"Missing source-tag/source-commit entries for: {', '.join(missing)}")

    snapcraft_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


DEFAULTS = {
    "ftl": "v6.6.2",
    "pi_hole": "v6.4.2",
    "web": "v6.5",
}


def get_stable_versions(snapcraft_path):
    versions = {}
    current_part = None
    if snapcraft_path.exists():
        for raw in snapcraft_path.read_text(encoding="utf-8").splitlines():
            part_match = re.match(r"^  ([A-Za-z0-9_]+):\s*$", raw)
            if part_match:
                candidate = part_match.group(1)
                current_part = candidate if candidate in COMPONENTS else None
                continue

            if current_part:
                m = re.match(r"^    source-tag:\s*(\S+)\s*$", raw)
                if m:
                    versions[current_part] = m.group(1)

    for key, val in DEFAULTS.items():
        if key not in versions:
            versions[key] = val
    return versions


def main():
    parser = argparse.ArgumentParser(description="Select upstream Pi-hole sources for snapcraft builds.")
    parser.add_argument("channel", choices=["stable", "edge"])
    parser.add_argument("--snapcraft", default="snap/snapcraft.yaml")
    args = parser.parse_args()

    snapcraft_path = pathlib.Path(args.snapcraft)
    stable_versions = get_stable_versions(snapcraft_path)

    # Save stable versions to stable-versions.json in the same directory as this script
    script_dir = pathlib.Path(__file__).parent.resolve()
    json_path = script_dir / "stable-versions.json"
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(stable_versions, f, indent=2)
    print(f"Saved stable versions to {json_path}")

    if args.channel == "stable":
        print("Using committed stable upstream release tags from snap/snapcraft.yaml.")
        return

    versions = upstream_dev_versions(token=os.environ.get("GITHUB_TOKEN", ""))
    update_source_commits(snapcraft_path, versions)
    print(f"Selected upstream {UPSTREAM_EDGE_REF} commits for edge builds:")
    for key in ("ftl", "pi_hole", "web"):
        print(f"  {key}: {versions[key]}")


if __name__ == "__main__":
    main()
