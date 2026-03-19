# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability in `wild-session-telemetry`, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

### How to Report

1. Email security concerns to the maintainer privately
2. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Expected vs actual behavior
   - Impact assessment

### Response Timeline

- Acknowledgment within 48 hours
- Assessment and remediation plan within 7 days
- Fix deployed within 30 days for confirmed vulnerabilities

## Privacy Considerations

This library handles telemetry data with strict privacy controls:

- No raw parameter values are stored
- Per-event-type metadata allowlisting prevents PII leakage
- Aggregations are designed to prevent re-identification
- See `000-docs/003-TQ-STND-privacy-model.md` for the full privacy model
