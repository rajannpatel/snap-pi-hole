#!/usr/bin/env python3
"""Verify that selected upstream commits match packaged snap evidence."""

import argparse
import json
import pathlib
import re
import sys
from dataclasses import dataclass
from typing import Final, TypedDict

COMPONENT_KEYS: Final = ("ftl", "pi_hole", "web")
SBOM_NAMES: Final = {
    "ftl": "pihole-ftl",
    "pi_hole": "pi-hole",
    "web": "web",
}
VERSION_KEYS: Final = {
    "ftl": "FTL_VERSION",
    "pi_hole": "CORE_VERSION",
    "web": "WEB_VERSION",
}
FULL_COMMIT_PATTERN: Final = re.compile(r"^[0-9a-f]{40}$")
SOURCE_COMMIT_PATTERN: Final = re.compile(
    r'^    source-commit:\s*"?([0-9a-f]{40})"?\s*$'
)


class ComponentSelection(TypedDict):
    commit: str
    stable_version: str


class SelectionManifest(TypedDict):
    schema_version: int
    channel: str
    ref: str
    components: dict[str, ComponentSelection]


@dataclass(frozen=True, slots=True)
class VerificationError(Exception):
    message: str

    def __str__(self) -> str:
        return self.message


def load_manifest(path: pathlib.Path) -> SelectionManifest:
    with path.open(encoding="utf-8") as manifest_file:
        manifest: SelectionManifest = json.load(manifest_file)

    if manifest.get("schema_version") != 1:
        raise VerificationError("selection manifest schema_version must be 1")
    if manifest.get("channel") not in ("stable", "edge"):
        raise VerificationError("selection manifest channel must be stable or edge")

    components = manifest.get("components", {})
    for key in COMPONENT_KEYS:
        selection = components.get(key)
        if selection is None:
            raise VerificationError(f"selection manifest missing component {key}")
        commit = selection.get("commit", "")
        if not FULL_COMMIT_PATTERN.fullmatch(commit):
            raise VerificationError(f"selection manifest has invalid {key} commit {commit!r}")
        if not selection.get("stable_version", ""):
            raise VerificationError(f"selection manifest missing {key} stable_version")
    return manifest


def snapcraft_commits(path: pathlib.Path) -> dict[str, str]:
    commits: dict[str, str] = {}
    current_part = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        part_match = re.match(r"^  ([A-Za-z0-9_]+):\s*$", raw)
        if part_match:
            candidate = part_match.group(1)
            current_part = candidate if candidate in COMPONENT_KEYS else ""
            continue
        commit_match = SOURCE_COMMIT_PATTERN.match(raw)
        if current_part and commit_match:
            commits[current_part] = commit_match.group(1)
    return commits


def key_value_file(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        if "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        values[key] = value
    return values


def snap_version(path: pathlib.Path) -> str:
    for raw in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r'^version:\s*"?([^"]+)"?\s*$', raw)
        if match:
            return match.group(1)
    raise VerificationError(f"snap metadata missing version: {path}")


def sbom_versions(path: pathlib.Path) -> dict[str, str]:
    with path.open(encoding="utf-8") as sbom_file:
        sbom = json.load(sbom_file)
    versions: dict[str, str] = {}
    names_to_keys = {name: key for key, name in SBOM_NAMES.items()}
    for component in sbom.get("components", []):
        name = component.get("name", "")
        key = names_to_keys.get(name)
        if key:
            versions[key] = component.get("version", "")
    return versions


def expected_component_version(
    channel: str,
    key: str,
    selection: ComponentSelection,
) -> str:
    stable_version = selection["stable_version"]
    short_commit = selection["commit"][:7]
    if key == "pi_hole" or channel == "edge":
        return f"{stable_version}+git.{short_commit}"
    return stable_version


def verify_snapcraft(manifest: SelectionManifest, path: pathlib.Path) -> None:
    actual_commits = snapcraft_commits(path)
    for key in COMPONENT_KEYS:
        expected = manifest["components"][key]["commit"]
        actual = actual_commits.get(key, "")
        if actual != expected:
            raise VerificationError(
                f"{key} snapcraft source mismatch: expected {expected}, got {actual or '<missing>'}"
            )


def verify_artifact(
    manifest: SelectionManifest,
    extracted: pathlib.Path,
    sbom: pathlib.Path,
) -> str:
    versions_path = extracted / "opt" / "pihole" / "templates" / "versions"
    actual_versions = key_value_file(versions_path)
    actual_sbom_versions = sbom_versions(sbom)
    channel = manifest["channel"]
    expected_versions = {
        key: expected_component_version(channel, key, manifest["components"][key])
        for key in COMPONENT_KEYS
    }

    expected_snap_version = expected_versions["pi_hole"]
    actual_snap_version = snap_version(extracted / "meta" / "snap.yaml")
    if actual_snap_version != expected_snap_version:
        raise VerificationError(
            f"snap version mismatch: expected {expected_snap_version}, got {actual_snap_version}"
        )

    for key in COMPONENT_KEYS:
        expected = expected_versions[key]
        actual = actual_versions.get(VERSION_KEYS[key], "")
        if actual != expected:
            raise VerificationError(
                f"{key} versions template mismatch: expected {expected}, got {actual or '<missing>'}"
            )
        sbom_actual = actual_sbom_versions.get(key, "")
        if sbom_actual != expected:
            raise VerificationError(
                f"{key} SBOM version mismatch: expected {expected}, got {sbom_actual or '<missing>'}"
            )
    return expected_snap_version


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify selected upstream commits against snap packaging evidence."
    )
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    parser.add_argument("--snapcraft", required=True, type=pathlib.Path)
    parser.add_argument("--extracted", type=pathlib.Path)
    parser.add_argument("--sbom", type=pathlib.Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        manifest = load_manifest(args.manifest)
        verify_snapcraft(manifest, args.snapcraft)
        if (args.extracted is None) != (args.sbom is None):
            raise VerificationError("--extracted and --sbom must be provided together")
        if args.extracted is None:
            print(f"Verified selected upstream sources for {manifest['channel']}.")
            return 0
        version = verify_artifact(manifest, args.extracted, args.sbom)
    except (OSError, json.JSONDecodeError, VerificationError) as error:
        print(f"Selected upstream verification failed: {error}", file=sys.stderr)
        return 1

    print(
        f"Verified selected upstream artifact for {manifest['channel']}: {version}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
