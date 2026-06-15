#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import urllib.request


GITHUB_API = "https://api.github.com"
COMPONENTS = {
    "ftl": "pi-hole/FTL",
    "pi_hole": "pi-hole/pi-hole",
    "web": "pi-hole/web",
}


def github_json(url, token=""):
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "snap-pi-hole-upstream-version-resolver",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def git_describe_release(source_dir):
    if not source_dir:
        return ""
    try:
        tag = subprocess.check_output(
            ["git", "-C", source_dir, "describe", "--tags", "--abbrev=0", "--match", "v*"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return ""
    return tag if tag.startswith("v") else ""


def latest_release_tag(component, token=""):
    repo = COMPONENTS[component]
    try:
        data = github_json(f"{GITHUB_API}/repos/{repo}/releases/latest", token=token)
        tag = str(data.get("tag_name") or "").strip()
        if tag.startswith("v"):
            return tag
    except Exception:
        pass

    try:
        output = subprocess.check_output(
            [
                "git",
                "ls-remote",
                "--tags",
                "--refs",
                "--sort=-v:refname",
                f"https://github.com/{repo}.git",
                "refs/tags/v*",
            ],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        output = ""

    for line in output.splitlines():
        ref = line.split()[-1] if line.split() else ""
        tag = ref.removeprefix("refs/tags/")
        if tag.startswith("v"):
            return tag

    raise RuntimeError(f"Could not resolve a release tag for {repo}")


def resolve_release_tag(component, source_dir="", token=""):
    return git_describe_release(source_dir) or latest_release_tag(component, token=token)


def latest_release_versions(token=""):
    return {key: latest_release_tag(key, token=token) for key in COMPONENTS}


def main():
    parser = argparse.ArgumentParser(description="Resolve Pi-hole upstream release labels.")
    parser.add_argument("component", choices=sorted(COMPONENTS))
    parser.add_argument("--source-dir", default="")
    args = parser.parse_args()

    token = os.environ.get("GITHUB_TOKEN", "")
    print(resolve_release_tag(args.component, source_dir=args.source_dir, token=token))


if __name__ == "__main__":
    main()
