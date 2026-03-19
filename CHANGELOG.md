# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-03-19

### Added

#### Epic 1: Foundation + Event Receiver
- `Schema::EventEnvelope` — immutable event data model with 9 fields
- `Schema::Validator` — ingestion-boundary validation (required fields, type checking, known values)
- `Privacy::Filter` — top-level field stripping + per-event-type metadata allowlisting
- `Collector::EventReceiver` — fire-and-forget ingestion with validation + privacy filtering
- `Store::MemoryStore` — thread-safe in-memory storage for testing
- `Configuration` — startup-only configuration with defaults

#### Epic 2: Durable Storage
- `Store::JsonLinesStore` — append-only file-based storage with mutex protection
- `Store::RetentionManager` — time-based and size-based purge
- `Store::StorageMonitor` — health checks and storage statistics
- `Configuration.max_storage_bytes` — configurable storage size limit

#### Epic 3: Privacy Hardening
- `Privacy::Filter::FORBIDDEN_FIELD_NAMES` — 22 dangerous field names explicitly blocked
- `Privacy::Filter::ALLOWED_VALUE_TYPES` — metadata value type validation (rejects Hash/Array)
- `Configuration#freeze!` — explicit freeze method with setter guards
- Auto-freeze configuration after `WildSessionTelemetry.configure` block

#### Epic 4: Export Pipeline
- `Export::RecordBuilder` — transforms data into typed export records
- `Export::Exporter` — JSON Lines export with filtering (since, before, event_type, caller_id)
- Schema-versioned header with record counts

#### Epic 5: Aggregation
- `Aggregation::Engine` — 4 aggregation methods with population threshold suppression
  - `session_summaries` — windowed by caller_id with outcome breakdowns
  - `tool_utilization` — per-action stats (success rate, avg duration, unique callers)
  - `outcome_distributions` — per-action percentage breakdowns
  - `latency_stats` — p50/p95/p99 percentiles per action
- Exporter integration with optional aggregator

#### Epic 6: Pattern Detection
- `Aggregation::PatternDetector` — sequential pattern and failure cascade detection
  - `detect_sequences` — groups events into sessions, extracts subsequences, ranks by frequency
  - `detect_failure_cascades` — same approach on error/denied events only
- Exporter integration with optional pattern_detector

#### Epic 7: Integration Testing
- Full pipeline integration tests (EventReceiver → store → aggregate → export)
- Volume test (200+ events)
- JsonLinesStore durability test across reloads
- Error path and privacy filter pipeline verification

#### Epic 8: Adversarial Testing
- Privacy invariants tests (8 invariants from doc 003)
- Safety rules tests (8 rules from doc 005)
- Threat mitigation tests (8 threats from doc 006)

#### Epic 9: Operator Documentation
- Configuration reference (doc 008)
- Operator deployment guide (doc 009)
- Operator workflow guide (doc 010)
- Updated README and CLAUDE.md for v1 status

#### Epic 10: Expansion Readiness
- v2 expansion roadmap (doc 011)
- Confirmed out-of-scope (doc 012)
- Full v0.1.0 release notes

### Documentation
- 12 canonical docs in 000-docs/ covering planning, standards, architecture, operations
- Complete doc index with filing code reference

### Test Coverage
- 325 examples, 0 failures
- Unit tests per module
- Integration tests (full pipeline)
- Adversarial tests (privacy invariants, safety rules, threat mitigations)

### Quality
- 0 rubocop offenses
- CI green on Ruby 3.2 and 3.3
- Gemini code review on all PRs
