# Contributing to wild-session-telemetry

Thank you for your interest in contributing. This project is currently maintained internally, but we welcome security reports and feedback.

## Before Contributing

1. Read `CLAUDE.md` for project context and conventions
2. Read `000-docs/003-TQ-STND-privacy-model.md` for privacy requirements
3. Read `000-docs/005-TQ-STND-safety-model.md` for safety rules
4. Read `000-docs/006-AT-ADEC-threat-model.md` for security considerations

## Privacy Rules

These are **non-negotiable** when contributing to this codebase:

1. **Never store raw parameter values** from pipeline operations
2. **Validate at ingestion boundary** — reject invalid events silently
3. **Strip unknown fields** before storage
4. **Fire-and-forget** — telemetry failures never propagate
5. **Per-event-type allowlisting** — only known metadata fields pass through

## Development Setup

```bash
bundle install
bundle exec rspec     # Run tests
bundle exec rubocop   # Lint
```

## Pull Requests

1. Fork the repo and create a feature branch
2. Write tests for any new functionality
3. Ensure `bundle exec rspec` passes with 0 failures
4. Ensure `bundle exec rubocop` passes with 0 offenses
5. Open a pull request with a clear description
