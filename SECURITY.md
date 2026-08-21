# Security Policy

SBM controls a privileged helper and processes untrusted VPN profiles, so
security reports are welcome.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability.

Use GitHub's private vulnerability reporting for this repository:

https://github.com/stillnotfree/SBM/security/advisories/new

Include the affected SBM and macOS versions, a concise reproduction, and the
expected security impact. Do not include real subscription URLs, credentials,
private keys, or unredacted diagnostic output.

## Scope

The latest public release is supported. Reports about the application,
privileged helper, profile validation, updater, local control interface, and
packaging are in scope.

This project has not received an independent professional security audit.

Website Routing accepts only bounded normalized hostnames (or unambiguous
HTTP/HTTPS URLs without credentials), stores typed Proxy/Direct/Reject targets,
and cannot inject arbitrary sing-box fields or outbound tags. Mandatory SBM
safety rules remain above website and application routing.

Diagnostics retains at most 50 recent errors. Errors are redacted before
retention and again when text or JSON is copied; subscription URLs, sensitive
headers, credentials, raw native JSON, profile bodies, helper secrets, and raw
core logs are excluded. Diagnostics performs no DNS or network probes.
Error history is byte-budgeted during export so current status is retained and
truncation is explicit. An unreachable helper produces an unknown core state,
not a claim that the privileged VPN core has stopped; termination remains
fail-closed unless a stopped response is known.
