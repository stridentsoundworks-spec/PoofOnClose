# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 2.1.x   | Yes       |
| < 2.1   | No        |

## Reporting a Vulnerability

If you discover a security vulnerability in PoofOnClose, please report it responsibly rather than opening a public issue.

**Contact:** Open a [private security advisory](https://github.com/stridentsoundworks-spec/PoofOnClose/security/advisories/new) on this repository, or email the maintainer directly.

We aim to acknowledge reports within 48 hours and provide a fix or mitigation plan within 7 days.

## Security Posture

- **Zero external dependencies** — single Swift file compiled against macOS system frameworks only.
- **No network activity** — the app makes no outbound connections.
- **No file I/O** — preferences stored via `UserDefaults` only.
- **CI/CD hardened** — GitHub Actions pinned to commit SHAs with least-privilege permissions.
- **Branch protection** — `main` requires status checks to pass; force pushes blocked.

## Audit History

| Date | Auditor | Scope | Grade |
|------|---------|-------|-------|
| 2026-04-09 | Weave (Perplexity Computer) | Full source, CI/CD, supply chain | A- |
