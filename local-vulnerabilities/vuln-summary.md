# Vulnerability Summary

All available security updates are automatically applied during compilation at build time.
This report lists both actionable vulnerabilities (with a corresponding Ubuntu Security Notice) and unactionable vulnerabilities (no patch available yet).
Strict snap confinement mitigates risks from unpatched vulnerabilities by running the application in a highly isolated sandbox.

## amd64

- Unpatched packages: 1
- Vulnerability matches: 2
- JSON report: `osv-amd64.json`

| Package | Version | Vulnerability | CVSS 3 | Priority | Status | Published |
| --- | --- | --- | --- | --- | --- | --- |
| curl | 7.88.1-10+deb12u1 | [CVE-2023-38545](https://osv.dev/vulnerability/CVE-2023-38545) | 9.8 · Critical | unknown | Actionable (USN) | 2023-10-11 |
| curl | 7.88.1-10+deb12u1 | [CVE-2023-99999](https://osv.dev/vulnerability/CVE-2023-99999) | 4.7 · Medium | unknown | Confined Mitigation | 2023-12-01 |

