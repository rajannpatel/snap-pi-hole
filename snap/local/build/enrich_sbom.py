#!/usr/bin/env python3
import json
import sys
import os

PROJECT_LICENSES = {
    "pihole-ftl": "GPL-3.0-only",
    "pi-hole": "GPL-3.0-only",
    "pihole": "GPL-3.0-only",
    "web": "MIT",
}

def find_license_in_copyright(extracted_snap_dir, package_name):
    # Normalize package name (e.g., "libssl3:amd64" -> "libssl3")
    name = package_name.split(':')[0]

    # Paths to search in extracted snap
    copyright_path = os.path.join(extracted_snap_dir, "usr", "share", "doc", name, "copyright")

    if not os.path.exists(copyright_path):
        # Try lowercase or other variations
        copyright_path = os.path.join(extracted_snap_dir, "usr", "share", "doc", name.lower(), "copyright")
        if not os.path.exists(copyright_path):
            return None

    try:
        with open(copyright_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()

        # 1. Try to find DEP-5 machine-readable License field
        for line in content.splitlines():
            line_strip = line.strip()
            if line_strip.lower().startswith("license:"):
                lic = line_strip[len("license:"):].strip()
                if lic and lic.upper() not in ("", "NONE", "NULL", "UNKNOWN"):
                    return lic

        # 2. Heuristic fallback: Search text content for standard license names
        content_lower = content.lower()
        if "gnu general public license" in content_lower:
            if "version 3" in content_lower:
                return "GPL-3.0-or-later"
            elif "version 2" in content_lower:
                return "GPL-2.0-or-later"
            return "GPL"
        if "gnu lesser general public license" in content_lower or "gnu library general public license" in content_lower:
            if "version 3" in content_lower:
                return "LGPL-3.0-or-later"
            elif "version 2" in content_lower:
                return "LGPL-2.1-or-later"
            return "LGPL"
        if "mit license" in content_lower or "mit/x11" in content_lower or "permission is hereby granted, free of charge" in content_lower:
            return "MIT"
        if "apache license" in content_lower:
            if "2.0" in content_lower:
                return "Apache-2.0"
            return "Apache"
        if "bsd 3-clause" in content_lower or "3-clause bsd" in content_lower:
            return "BSD-3-Clause"
        if "bsd 2-clause" in content_lower or "2-clause bsd" in content_lower:
            return "BSD-2-Clause"
        if "mozilla public license" in content_lower or "mpl" in content_lower:
            return "MPL-2.0"
        if "openssl license" in content_lower:
            return "OpenSSL"
        if "zlib license" in content_lower:
            return "Zlib"

    except Exception as e:
        print(f"Warning: Failed to read copyright file for {package_name}: {e}", file=sys.stderr)

    return None

def enrich_sbom(file_path, extracted_snap_dir):
    if not os.path.exists(file_path):
        print(f"Error: file not found: {file_path}", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(extracted_snap_dir):
        print(f"Error: extracted snap directory not found: {extracted_snap_dir}", file=sys.stderr)
        sys.exit(1)

    with open(file_path, 'r') as f:
        data = json.load(f)

    components = data.get("components", [])
    modified_count = 0

    for comp in components:
        name = comp.get("name", "")
        licenses = comp.get("licenses", [])
        has_valid_license = False

        if licenses:
            for l_item in licenses:
                lic = l_item.get("license", {})
                lic_id = lic.get("id") or lic.get("name")
                if lic_id and lic_id.upper() not in ("", "NONE", "NULL"):
                    has_valid_license = True
                    break

        if not has_valid_license:
            matched_license = None
            normalized_name = name.lower()

            # 1. Project primary components check
            if normalized_name in PROJECT_LICENSES:
                matched_license = PROJECT_LICENSES[normalized_name]
            else:
                # 2. Resolve dynamically from Debian/Ubuntu copyright files
                matched_license = find_license_in_copyright(extracted_snap_dir, name)

            if matched_license:
                # Set CycloneDX license structure
                comp["licenses"] = [{
                    "license": {
                        "id": matched_license if " OR " not in matched_license and " WITH " not in matched_license and matched_license not in ("GPL", "LGPL", "Apache") else None,
                        "name": matched_license
                    }
                }]
                modified_count += 1
                print(f"Enriched: {name} -> {matched_license}")

    if modified_count > 0:
        with open(file_path, 'w') as f:
            json.dump(data, f, indent=2)
        print(f"Successfully enriched {modified_count} components in {file_path}")
    else:
        print(f"No missing licenses resolved for {file_path}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: enrich-sbom.py <path_to_sbom.json> <path_to_extracted_snap>", file=sys.stderr)
        sys.exit(1)
    enrich_sbom(sys.argv[1], sys.argv[2])
