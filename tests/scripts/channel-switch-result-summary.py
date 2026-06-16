#!/usr/bin/env python3
import json
import os
import sys

def main():
    args = sys.argv[1:]
    allow_failure = False
    if "--allow-failure" in args:
        allow_failure = True
        args = [arg for arg in args if arg != "--allow-failure"]
        
    if not args:
        print("No result files provided.")
        sys.exit(0)
        
    failed = False
    summary_lines = []
    summary_lines.append("# Channel Switch Smoke Test Summary\n")
    
    for filepath in args:
        if not os.path.exists(filepath):
            continue
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:
            summary_lines.append(f"### Failed to read {filepath}: {e}\n")
            failed = True
            continue
            
        arch = data.get("arch", "unknown")
        status = data.get("status", "unknown")
        reason = data.get("reason", "")
        path = data.get("path", "unknown")
        transitions = data.get("transitions", [])
        warnings = data.get("warnings", [])
        
        status_emoji = "✅" if status == "success" else ("⚠️" if status == "skipped" else "❌")
        summary_lines.append(f"## {status_emoji} Architecture: {arch} ({status.upper()})")
        summary_lines.append(f"- **Path tested:** `{path}`")
        if reason:
            summary_lines.append(f"- **Reason:** `{reason}`")
            
        if status == "success":
            summary_lines.append("- **Transitions:**")
            for t in transitions:
                from_c = t.get("from", "unknown")
                to_c = t.get("to", "unknown")
                from_r = t.get("from_revision", "unknown")
                to_r = t.get("to_revision", "unknown")
                t_status = t.get("status", "unknown")
                t_emoji = "✅" if t_status == "success" else "❌"
                summary_lines.append(f"  - {t_emoji} `{from_c}` (r{from_r}) &rarr; `{to_c}` (r{to_r}): **{t_status}**")
        elif status == "failure":
            failed = True
            if transitions:
                summary_lines.append("- **Failed Transition Details:**")
                for t in transitions:
                    t_status = t.get("status", "unknown")
                    if t_status == "failure":
                        from_c = t.get("from", "unknown")
                        to_c = t.get("to", "unknown")
                        checks = t.get("checks", {})
                        failed_checks = [k for k, v in checks.items() if v == 'failure']
                        summary_lines.append(f"  - `{from_c}` &rarr; `{to_c}` failed checks: `{', '.join(failed_checks)}`")
                        
        if warnings:
            summary_lines.append("- **Warnings:**")
            for w in warnings:
                summary_lines.append(f"  - `{w}`")
        summary_lines.append("")

    markdown_text = "\n".join(summary_lines)
    
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        with open(summary_file, "a", encoding="utf-8") as sf:
            sf.write(markdown_text)
    else:
        print(markdown_text)
        
    if failed and not allow_failure:
        sys.exit(1)
    sys.exit(0)

if __name__ == "__main__":
    main()
