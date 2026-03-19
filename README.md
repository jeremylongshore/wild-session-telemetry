# wild-session-telemetry

Privacy-aware telemetry collection and export from agent sessions.

Part of the **wild** ecosystem — Wave 2 observability pipeline. Receives structured events from operational repos (`wild-admin-tools-mcp`, `wild-rails-safe-introspection-mcp`) and produces aggregated, privacy-safe usage data for downstream analysis by `wild-gap-miner` and `wild-transcript-pipeline`.

![Status](https://img.shields.io/badge/status-v1_complete-brightgreen)
![Ruby](https://img.shields.io/badge/ruby-3.2%2B-red)
![License](https://img.shields.io/badge/license-proprietary-blue)

## Quick Start

Add to your Gemfile:

```ruby
gem 'wild-session-telemetry', git: 'https://github.com/jeremylongshore/wild-session-telemetry.git'
```

Configure and use:

```ruby
require 'wild_session_telemetry'

# Configure (freezes after block completes)
WildSessionTelemetry.configure do |config|
  config.store = WildSessionTelemetry::Store::JsonLinesStore.new(path: 'tmp/telemetry.jsonl')
  config.retention_days = 90
end

# Create receiver and attach to upstream emitter
store = WildSessionTelemetry.configuration.store
receiver = WildSessionTelemetry::Collector::EventReceiver.new(store: store)

# Receive events (fire-and-forget)
receiver.receive({
  event_type: "action.completed",
  timestamp: Time.now.utc.iso8601(3),
  caller_id: "service-account-ops",
  action: "retry_job",
  outcome: "success",
  duration_ms: 42.5,
  metadata: { category: "background_jobs", phase: "execute" }
})

# Export
exporter = WildSessionTelemetry::Export::Exporter.new(
  store: store,
  aggregator: WildSessionTelemetry::Aggregation::Engine.new,
  pattern_detector: WildSessionTelemetry::Aggregation::PatternDetector.new
)
lines = exporter.export(since: '2026-03-01T00:00:00Z')
```

## Event Types

Three event types are defined by the telemetry emission hook interface:

| Event Type | Fires When | Key Metadata |
|------------|-----------|--------------|
| `action.completed` | Every pipeline invocation (success, denial, error, preview) | `category`, `operation`, `phase`, `denial_reason`, `blast_radius_count`, `confirmation_used` |
| `gate.evaluated` | Every capability gate check (allowed, denied, errored) | `gate_result`, `capability_checked` |
| `rate_limit.checked` | Every rate limit evaluation (allowed, exceeded) | `rate_result`, `current_count`, `limit`, `window_seconds` |

All events share a common envelope: `event_type`, `timestamp`, `caller_id`, `action`, `outcome`, `duration_ms`, `metadata`.

## Privacy Summary

**Collected:** Action names, outcomes, timing, caller identity tokens, gate results, rate limit counters.

**Excluded:**
- Raw parameter values (may contain PII)
- Before/after snapshot data (contains system state)
- Nonce values (security-sensitive tokens)
- Error stack traces (may expose internal state)
- Adapter-specific identifiers (job IDs, cache keys, flag names)

All exclusions are enforced by hardcoded forbidden field lists and per-event-type metadata allowlists. Configuration is frozen after startup. See `000-docs/003-TQ-STND-privacy-model.md`.

## Architecture

`wild-session-telemetry` is a **pure Ruby library gem**. No MCP server, no ActiveRecord, no web framework dependency.

```
Upstream emitter  -->  [EventReceiver]  -->  [Privacy::Filter + Validator]
                                                       |
                                                  [Store layer]
                                                  /           \
                                          MemoryStore    JsonLinesStore
                                                  \           /
                                            [Aggregation::Engine]
                                            [PatternDetector]
                                                     |
                                              [Export::Exporter]
```

- **Ingestion:** Validates event schema, strips forbidden fields, enforces per-type metadata allowlists
- **Storage:** Pluggable store backends (MemoryStore for testing, JsonLinesStore for production)
- **Aggregation:** Session summaries, tool utilization, outcome distributions, latency percentiles (p50/p95/p99)
- **Pattern Detection:** Sequential action patterns and failure cascade detection
- **Export:** JSON Lines output with schema-versioned header, typed records, and aggregations

Storage is bounded. Events are immutable after ingestion. Configuration is frozen after startup. All telemetry failures are swallowed (fire-and-forget semantics).

## Export Format

Exports produce JSON Lines files. First line is a metadata header with `schema_version`, `time_range`, and `record_counts`. Subsequent lines are typed records: `event`, `session_summary`, `tool_utilization`, `outcome_distribution`, `latency_stats`, `pattern`.

See `000-docs/004-AT-STND-data-contracts.md` for the complete export contract.

## Non-Goals

This repo intentionally does not:

- Serve as an MCP server (upstream repos own their MCP layers)
- Provide a dashboard or visualization layer
- Collect or store PII in any form
- Normalize transcripts (that is `wild-transcript-pipeline`)
- Perform gap analysis (that is `wild-gap-miner`)
- Act as a generic event bus or message broker
- Replace per-repo audit trails (audit logs remain authoritative; telemetry is derived)
- Support real-time streaming or pub/sub delivery

## Canonical Docs

| Doc | Purpose |
|-----|---------|
| `001-PP-PLAN-repo-blueprint.md` | Mission, boundaries, architecture direction |
| `002-PP-PLAN-epic-build-plan.md` | 10-epic build plan with sequencing and dependencies |
| `003-TQ-STND-privacy-model.md` | Privacy specification — what is collected, what is excluded |
| `004-AT-STND-data-contracts.md` | Input/output contracts, export schema, versioning |
| `005-TQ-STND-safety-model.md` | 8 enforceable safety rules |
| `006-AT-ADEC-threat-model.md` | 8 threats with mitigations |
| `007-AT-ADEC-architecture-decisions.md` | 7 key design decisions with rationale |
| `008-DR-REFF-configuration-reference.md` | Every parameter, type, default, range |
| `009-OD-OPNS-operator-deployment-guide.md` | Setup, configure, attach, verify |
| `010-OD-GUID-operator-workflow-guide.md` | Health checks, querying, exports, retention |

## Development

```bash
bundle install          # Install dependencies
bundle exec rspec       # Run test suite (325 examples)
bundle exec rubocop     # Lint (0 offenses)
```

## License

Intent Solutions Proprietary. See [LICENSE](LICENSE) for details.
