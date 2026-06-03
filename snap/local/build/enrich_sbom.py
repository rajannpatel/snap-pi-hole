#!/usr/bin/env python3
import json
import sys
import os
import re

PROJECT_LICENSES = {
    "pihole-ftl": "GPL-3.0-only",
    "pi-hole": "GPL-3.0-only",
    "pihole": "GPL-3.0-only",
    "web": "MIT",
    "rust-coreutils": "MIT",
}

def find_license_in_copyright(extracted_snap_dir, package_name):
    # Normalize package name (e.g., "libssl3:amd64" -> "libssl3")
    name = package_name.split(':')[0].lower()

    # Paths to search in extracted snap
    doc_dir = os.path.join(extracted_snap_dir, "usr", "share", "doc")
    if not os.path.exists(doc_dir):
        return None

    def check_dir(dir_name):
        path = os.path.join(doc_dir, dir_name, "copyright")
        if os.path.exists(path):
            try:
                with open(path, 'r', encoding='utf-8', errors='ignore') as f:
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
                print(f"Warning: Failed to read copyright file for {dir_name}: {e}", file=sys.stderr)
        return None

    # Step 1: Exact matches
    all_dirs = [d for d in os.listdir(doc_dir) if os.path.isdir(os.path.join(doc_dir, d))]
    for d in all_dirs:
        if d.lower() == name:
            lic = check_dir(d)
            if lic:
                return lic

    # Step 2: Try checking directories that share a common stem
    for d in all_dirs:
        d_lower = d.lower()
        def get_stem(s):
            stem = s
            if stem.startswith("lib"):
                stem = stem[3:]
            # strip numeric suffixes or t64
            stem = re.sub(r'\d+.*$', '', stem)
            stem = re.sub(r't\d+$', '', stem)
            return stem.strip("-")

        name_stem = get_stem(name)
        d_stem = get_stem(d_lower)

        if name_stem and d_stem and len(name_stem) >= 2 and name_stem == d_stem:
            lic = check_dir(d)
            if lic:
                return lic

    # Step 3: Specific fallbacks
    special_mappings = {
        "openldap": "ldap",
        "cyrus-sasl2": "sasl",
        "rtmpdump": "rtmp",
    }
    for key, val in special_mappings.items():
        if key in name:
            for d in all_dirs:
                if val in d.lower():
                    lic = check_dir(d)
                    if lic:
                        return lic

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
    filtered_components = []
    modified_count = 0
    removed_files_count = 0

    for comp in components:
        if comp.get("type") == "file":
            removed_files_count += 1
            continue

        filtered_components.append(comp)
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

    data["components"] = filtered_components

    if modified_count > 0 or removed_files_count > 0:
        with open(file_path, 'w') as f:
            json.dump(data, f, indent=2)
        if removed_files_count > 0:
            print(f"Removed {removed_files_count} file-type components.")
        if modified_count > 0:
            print(f"Successfully enriched {modified_count} components in {file_path}")
    else:
        print(f"No missing licenses resolved for {file_path}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: enrich-sbom.py <path_to_sbom.json> <path_to_extracted_snap>", file=sys.stderr)
        sys.exit(1)
    enrich_sbom(sys.argv[1], sys.argv[2])
