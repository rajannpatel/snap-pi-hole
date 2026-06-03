#!/usr/bin/env python3
import json
import sys
import os
import re
import gzip
import subprocess

PROJECT_LICENSES = {
    "pihole-ftl": "GPL-3.0-only",
    "pi-hole": "GPL-3.0-only",
    "pihole": "GPL-3.0-only",
    "web": "MIT",
    "rust-coreutils": "MIT",
}

APPLICATION_PACKAGES = {
    "bind9",
    "coreutils",
    "curl",
    "iproute2",
    "jq",
    "rtmpdump",
    "rust-coreutils",
    "sqlite3",
    "pihole-ftl",
    "pi-hole",
    "pihole",
    "web",
}


# NOTE: INJECTED_COMPONENTS was removed. All components are now discovered
# dynamically at runtime: FTL shared-library dependencies via `ldd`, and
# web frontend dependencies via the package.json shipped inside the snap.


def normalize_license(lic_str):
    # Normalize common license shorthand strings to SPDX identifiers
    mapping = {
        "gpl-2": ["GPL-2.0-only"],
        "gpl-2+": ["GPL-2.0-only", "GPL-2.0-or-later"],
        "gpl-2.0+": ["GPL-2.0-only", "GPL-2.0-or-later"],
        "gpl-3": ["GPL-3.0-only"],
        "gpl-3+": ["GPL-3.0-only", "GPL-3.0-or-later"],
        "gpl-3.0+": ["GPL-3.0-only", "GPL-3.0-or-later"],
        "lgpl-2": ["LGPL-2.0-only"],
        "lgpl-2+": ["LGPL-2.0-only", "LGPL-2.0-or-later"],
        "lgpl-2.0+": ["LGPL-2.0-only", "LGPL-2.0-or-later"],
        "lgpl-2.1": ["LGPL-2.1-only"],
        "lgpl-2.1+": ["LGPL-2.1-only", "LGPL-2.1-or-later"],
        "lgpl-3": ["LGPL-3.0-only"],
        "lgpl-3+": ["LGPL-3.0-only", "LGPL-3.0-or-later"],
        "lgpl-3.0+": ["LGPL-3.0-only", "LGPL-3.0-or-later"],
        "bsd-3-clause": ["BSD-3-Clause"],
        "bsd-2-clause": ["BSD-2-Clause"],
        "mit": ["MIT"],
        "apache-2.0": ["Apache-2.0"],
    }
    key = lic_str.strip().lower()
    return mapping.get(key, [lic_str])

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

                found_licenses = set()
                # 1. Try to find DEP-5 machine-readable License field
                for line in content.splitlines():
                    line_strip = line.strip()
                    if line_strip.lower().startswith("license:"):
                        lic = line_strip[len("license:"):].strip()
                        if lic and lic.upper() not in ("", "NONE", "NULL", "UNKNOWN"):
                            # Split on "or"/"and" keywords, comma, slash, or plain whitespace
                            for part in re.split(r'(?:\s+(?:or|and)\s+)|,\s*|/\s*|\s+', lic, flags=re.IGNORECASE):
                                part = part.strip()
                                if part:
                                    for normalized in normalize_license(part):
                                        found_licenses.add(normalized)

                if found_licenses:
                    return sorted(list(found_licenses))

                # 2. Heuristic fallback: Search text content for standard license names
                content_lower = content.lower()
                heuristics = []
                if "gnu general public license" in content_lower:
                    if "version 3" in content_lower:
                        heuristics.extend(["GPL-3.0-only", "GPL-3.0-or-later"])
                    elif "version 2" in content_lower:
                        heuristics.extend(["GPL-2.0-only", "GPL-2.0-or-later"])
                    else:
                        heuristics.append("GPL")
                if "gnu lesser general public license" in content_lower or "gnu library general public license" in content_lower:
                    if "version 3" in content_lower:
                        heuristics.extend(["LGPL-3.0-only", "LGPL-3.0-or-later"])
                    elif "version 2" in content_lower:
                        heuristics.extend(["LGPL-2.1-only", "LGPL-2.1-or-later"])
                    else:
                        heuristics.append("LGPL")
                if "mit license" in content_lower or "mit/x11" in content_lower or "permission is hereby granted, free of charge" in content_lower:
                    heuristics.append("MIT")
                if "apache license" in content_lower:
                    if "2.0" in content_lower:
                        heuristics.append("Apache-2.0")
                    else:
                        heuristics.append("Apache")
                if "bsd 3-clause" in content_lower or "3-clause bsd" in content_lower:
                    heuristics.append("BSD-3-Clause")
                if "bsd 2-clause" in content_lower or "2-clause bsd" in content_lower:
                    heuristics.append("BSD-2-Clause")
                if "mozilla public license" in content_lower or "mpl" in content_lower:
                    heuristics.append("MPL-2.0")
                if "openssl license" in content_lower:
                    heuristics.append("OpenSSL")
                if "zlib license" in content_lower:
                    heuristics.append("Zlib")

                if heuristics:
                    return sorted(list(set(heuristics)))
            except Exception as e:
                print(f"Warning: Failed to read copyright file for {dir_name}: {e}", file=sys.stderr)
        return None

    # Step 1: Exact matches
    all_dirs = [d for d in os.listdir(doc_dir) if os.path.isdir(os.path.join(doc_dir, d))]
    for d in all_dirs:
        if d.lower() == name:
            lics = check_dir(d)
            if lics:
                return lics

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
            lics = check_dir(d)
            if lics:
                return lics

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
                    lics = check_dir(d)
                    if lics:
                        return lics

    return None


def resolve_version_from_status(name, extracted_snap_dir):
    """Look up the installed version of `name` from the extracted dpkg/status file.
    Falls back to parsing changelog.Debian.gz when dpkg/status has no entry."""
    status_path = os.path.join(extracted_snap_dir, "var", "lib", "dpkg", "status")
    if os.path.exists(status_path):
        try:
            with open(status_path, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
            current_pkg = None
            for line in content.splitlines():
                if line.startswith("Package:"):
                    current_pkg = line.split(":", 1)[1].strip().lower()
                elif line.startswith("Version:") and current_pkg == name.lower():
                    return line.split(":", 1)[1].strip()
        except Exception as e:
            print(f"Warning: failed to read dpkg status for {name}: {e}", file=sys.stderr)

    # Fallback: parse the first line of changelog.Debian.gz
    changelog_path = os.path.join(
        extracted_snap_dir, "usr", "share", "doc", name, "changelog.Debian.gz"
    )
    if os.path.exists(changelog_path):
        try:
            with gzip.open(changelog_path, 'rt', encoding='utf-8', errors='ignore') as f:
                first_line = f.readline()
            # Format: "pkgname (version) suite; urgency=..."
            m = re.match(r'^\S+\s+\(([^)]+)\)', first_line)
            if m:
                return m.group(1)
        except Exception as e:
            print(f"Warning: failed to read changelog for {name}: {e}", file=sys.stderr)

    return None


def discover_ftl_embedded_dependencies(extracted_snap_dir):
    """Scan the pihole-FTL binary with ldd to find its shared-library dependencies,
    then resolve version and license for each one from the extracted snap filesystem.
    Returns a list of CycloneDX component dicts."""
    ftl_path = os.path.join(extracted_snap_dir, "usr", "sbin", "pihole-FTL")
    if not os.path.isfile(ftl_path):
        print(f"Warning: pihole-FTL not found at {ftl_path}; skipping FTL dependency discovery.",
              file=sys.stderr)
        return []

    try:
        proc = subprocess.run(
            ["ldd", ftl_path],
            capture_output=True, text=True, check=False
        )
    except FileNotFoundError:
        print("Warning: ldd not available; skipping FTL dependency discovery.", file=sys.stderr)
        return []

    # Parse ldd output: each useful line looks like
    #   libfoo.so.2 => /path/to/libfoo.so.2 (0x…)
    deps = set()
    for line in proc.stdout.splitlines():
        parts = line.split("=>")
        if len(parts) == 2:
            lib_path = parts[1].strip().split()[0]
            if lib_path and lib_path != "not" and lib_path.startswith("/"):
                deps.add(os.path.basename(lib_path))

    components = []
    for lib_filename in sorted(deps):
        # Derive a clean component name: strip leading "lib" and trailing ".so*"
        name = lib_filename
        if name.startswith("lib"):
            name = name[3:]
        name = re.split(r'\.so', name)[0]
        if not name:
            continue

        version = resolve_version_from_status(name, extracted_snap_dir) or "0.0"
        license_ids = find_license_in_copyright(extracted_snap_dir, name) or []
        licenses = [
            {"license": {"id": lic, "name": lic}}
            for lic in license_ids
        ]

        components.append({
            "type": "library",
            "name": name,
            "version": version,
            "licenses": licenses,
            "purl": f"pkg:generic/{name}@{version}"
        })
        print(f"Discovered FTL dependency: {name} {version}")

    return components


def discover_web_frontend_dependencies(extracted_snap_dir):
    """Read the web admin's package.json from the extracted snap to discover
    all npm dependencies (name, version, license) and return CycloneDX component dicts.
    The package.json lives at var/www/html/admin/package.json inside the snap."""
    pkg_json_path = os.path.join(
        extracted_snap_dir, "var", "www", "html", "admin", "package.json"
    )
    if not os.path.isfile(pkg_json_path):
        print(
            f"Warning: web package.json not found at {pkg_json_path}; "
            "skipping web frontend dependency discovery.",
            file=sys.stderr,
        )
        return []

    try:
        with open(pkg_json_path, "r", encoding="utf-8") as f:
            pkg = json.load(f)
    except Exception as e:
        print(f"Warning: failed to read {pkg_json_path}: {e}", file=sys.stderr)
        return []

    components = []
    for name, version in pkg.get("dependencies", {}).items():
        # version strings may start with ^ or ~ ; strip them for the SBOM
        version = version.lstrip("^~>= ")
        # Build a purl; percent-encode leading @ for scoped packages
        purl_name = name.replace("@", "%40").replace("/", "%2F") if name.startswith("@") else name
        purl = f"pkg:npm/{purl_name}@{version}"
        components.append({
            "type": "library",
            "name": name,
            "version": version,
            "licenses": [],   # will be enriched in the main loop via copyright lookup
            "purl": purl,
        })
        print(f"Discovered web frontend dependency: {name}@{version}")

    return components


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
    injected_count = 0
    # Dynamically discover libraries bundled with pihole-FTL at build time
    ftl_deps = discover_ftl_embedded_dependencies(extracted_snap_dir)
    components.extend(ftl_deps)
    injected_count += len(ftl_deps)
    # Dynamically discover web frontend dependencies from the admin package.json
    web_deps = discover_web_frontend_dependencies(extracted_snap_dir)
    components.extend(web_deps)
    injected_count += len(web_deps)

    filtered_components = []
    modified_count = 0
    removed_files_count = 0

    # 1. Filter out files
    for comp in components:
        if comp.get("type") == "file":
            removed_files_count += 1
            continue
        filtered_components.append(comp)

    # 2. Deduplicate components by name (case-insensitive)
    deduped = {}
    deduped_removed_count = 0
    for comp in filtered_components:
        name = comp.get("name", "")
        if not name:
            continue
        norm_name = name.lower()
        
        # Get the cataloger that found this package
        found_by = ""
        properties = comp.get("properties", [])
        for prop in properties:
            if prop.get("name") == "syft:package:foundBy":
                found_by = prop.get("value", "")
                break
        
        # Priority score
        score = 0
        if found_by == "dpkg-db-cataloger":
            score = 3
        elif found_by == "elf-binary-package-cataloger":
            score = 2
        elif found_by == "snap-cataloger":
            score = 1
        elif not found_by:
            score = 4
            
        # Prefer components with license info populated
        if comp.get("licenses"):
            score += 0.5
            
        if norm_name not in deduped:
            deduped[norm_name] = (score, comp)
        else:
            existing_score, existing_comp = deduped[norm_name]
            if score > existing_score:
                deduped[norm_name] = (score, comp)
            deduped_removed_count += 1
                
    # Sort final components list alphabetically by name
    filtered_components = [item[1] for item in sorted(deduped.values(), key=lambda x: x[1].get("name", "").lower())]

    # 3. Enrich licenses and classify types for deduplicated components
    for comp in filtered_components:
        name = comp.get("name", "")
        
        # Classify component type (application vs library)
        normalized_name = name.split(':')[0].lower()
        if normalized_name in APPLICATION_PACKAGES:
            comp["type"] = "application"
        else:
            comp["type"] = "library"

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
            matched_licenses = None
            normalized_name = name.lower()

            # 1. Project primary components check
            if normalized_name in PROJECT_LICENSES:
                matched_licenses = [PROJECT_LICENSES[normalized_name]]
            else:
                # 2. Resolve dynamically from Debian/Ubuntu copyright files
                matched_licenses = find_license_in_copyright(extracted_snap_dir, name)

            if matched_licenses:
                # Set CycloneDX license structure
                comp["licenses"] = [
                    {
                        "license": {
                            "id": lic if " OR " not in lic and " WITH " not in lic and lic not in ("GPL", "LGPL", "Apache") else None,
                            "name": lic
                        }
                    }
                    for lic in matched_licenses
                ]
                modified_count += 1
                print(f"Enriched: {name} -> {', '.join(matched_licenses)}")

    data["components"] = filtered_components

    if modified_count > 0 or removed_files_count > 0 or deduped_removed_count > 0 or injected_count > 0:
        with open(file_path, 'w') as f:
            json.dump(data, f, indent=2)
        if injected_count > 0:
            print(f"Injected {injected_count} dynamically discovered components.")
        if removed_files_count > 0:
            print(f"Removed {removed_files_count} file-type components.")
        if deduped_removed_count > 0:
            print(f"Removed {deduped_removed_count} duplicate components.")
        if modified_count > 0:
            print(f"Successfully enriched {modified_count} components in {file_path}")
    else:
        print(f"No missing licenses or duplicates resolved for {file_path}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: enrich-sbom.py <path_to_sbom.json> <path_to_extracted_snap>", file=sys.stderr)
        sys.exit(1)
    enrich_sbom(sys.argv[1], sys.argv[2])
