# Vulnerability Summary

All available security updates are automatically applied during compilation at build time.
Dashboard totals count only actionable vulnerabilities with a corresponding Ubuntu Security Notice (USN).
Raw OSV matches without a USN are retained as confined-mitigation report-only findings for audit visibility.
The CI workflow currently treats OSV exit code 1 as a warning and fails only if the scan itself errors.

## amd64

- Actionable USN packages: 1
- Actionable USN vulnerabilities: 1
- Raw OSV affected packages: 1
- Raw OSV vulnerability matches: 2
- Confined-mitigation report-only matches: 1
- JSON report: `osv-amd64.json`

| Package | Version | Vulnerability | CVSS 3 | Priority | Status | Published |
| --- | --- | --- | --- | --- | --- | --- |
| curl | 7.88.1-10+deb12u1 | [CVE-2023-38545](https://osv.dev/vulnerability/CVE-2023-38545) | 9.8 · Critical | unknown | Actionable (USN) | 2023-10-11 |
| curl | 7.88.1-10+deb12u1 | [CVE-2023-99999](https://osv.dev/vulnerability/CVE-2023-99999) | 4.7 · Medium | unknown | Confined Mitigation | 2023-12-01 |

## Confinement Analysis

Itemized security analysis of identified vulnerabilities and their exposure inside the strictly confined snap sandbox.

### CVE-2023-38545 (curl)

**✓ Contained by confinement**

- **Snap confinement mitigates risk**:
  Snap confinement (AppArmor, seccomp, and a read-only SquashFS root) restricts process capabilities and host access, containing CVE-2023-38545 within the sandbox so it cannot compromise the host.

### CVE-2023-99999 (curl)

**✓ Contained by confinement**

- **Snap confinement mitigates risk**:
  Snap confinement (AppArmor, seccomp, and a read-only SquashFS root) restricts process capabilities and host access, containing CVE-2023-99999 within the sandbox so it cannot compromise the host.

