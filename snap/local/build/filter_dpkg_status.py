#!/usr/bin/env python3
import sys
import os

def filter_status(prime_dir):
    status_path = os.environ.get("DPKG_STATUS_PATH", "/var/lib/dpkg/status")
    out_status_path = os.path.join(prime_dir, "var", "lib", "dpkg", "status")

    if not os.path.exists(status_path):
        print(f"Warning: Host/container dpkg status file not found: {status_path}")
        return

    with open(status_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    filtered_blocks = []
    kept_count = 0
    total_count = 0

    for block in content.split("\n\n"):
        if not block.strip():
            continue
        total_count += 1
        pkg_name = None
        for line in block.splitlines():
            if line.startswith("Package: "):
                pkg_name = line[len("Package: "):].strip()
                break
        if pkg_name:
            base_name = pkg_name.split(":")[0]
            # Check for copyright doc directory in the prime dir
            doc_dir1 = os.path.join(prime_dir, "usr", "share", "doc", pkg_name)
            doc_dir2 = os.path.join(prime_dir, "usr", "share", "doc", base_name)
            doc_dir3 = os.path.join(prime_dir, "usr", "share", "doc", pkg_name.lower())
            doc_dir4 = os.path.join(prime_dir, "usr", "share", "doc", base_name.lower())

            if os.path.exists(doc_dir1) or os.path.exists(doc_dir2) or os.path.exists(doc_dir3) or os.path.exists(doc_dir4):
                filtered_blocks.append(block)
                kept_count += 1

    os.makedirs(os.path.dirname(out_status_path), exist_ok=True)
    with open(out_status_path, "w", encoding="utf-8") as f:
        f.write("\n\n".join(filtered_blocks) + "\n")

    print(f"Filtered dpkg status: kept {kept_count} of {total_count} packages.")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: filter_dpkg_status.py <path_to_prime_directory>")
        sys.exit(1)
    filter_status(sys.argv[1])
