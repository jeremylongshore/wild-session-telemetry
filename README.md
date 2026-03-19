# wild-session-telemetry

Privacy-aware telemetry collection and export from agent sessions.

Part of the **wild** ecosystem — Wave 2 observability pipeline. Receives structured events from operational repos (`wild-admin-tools-mcp`, `wild-rails-safe-introspection-mcp`) and produces aggregated, privacy-safe usage data for downstream analysis by `wild-gap-miner` and `wild-transcript-pipeline`.

![Status](https://img.shields.io/badge/status-Epic_1_in_progress-yellow)
![Ruby](https://img.shields.io/badge/ruby-3.2%2B-red)
![License](https://img.shields.io/badge/license-proprietary-blue)

## Quick Start

Add to your Gemfile:

```ruby
gem 'wild-session-telemetry', git: 'https://github.com/jeremylongshore/wild-session-telemetry.git'
```

Require and configure:

```ruby
require 'wild_session_telemetry'

telemetry = WildSessionTelemetry::Client.new do |config|
  config.store = :json_lines          # :memory or :json_lines
  config.output_path = "tmp/telemetry"
  config.flush_interval = 60          # seconds
end
```

Receive events from an upstream emitter:

```ruby
# Any object responding to #receive(event) works as a subscriber
telemetry.receive({
  event_type: "action.completed",
  timestamp: Time.now.utc.iso8601(3),
  caller_id: "service-account-ops",
  action: "retry_job",
  outcome: "success",
  duration_ms: 42.5,
  metadata: { category: "background_jobs", phase: "execute" }
})
```

## Event Types

Three event types are defined by the telemetry emission hook interface (see `wild-admin-tools-mcp` doc 018):

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

Telemetry carries action names and outcomes only -- enough for usage analysis and pattern detection, not enough to reconstruct what specific resources were affected.

## Architecture

`wild-session-telemetry` is a **pure Ruby library gem**. No MCP server, no ActiveRecord, no web framework dependency.

```
Upstream emitter  -->  [Ingestion boundary]  -->  [Validation + stripping]
                                                         |
                                                    [Store layer]
                                                    /           \
                                            MemoryStore    JsonLinesStore
                                                    \           /
                                                  [Aggregation]
                                                       |
                                                    [Export]
```

- **Ingestion:** Validates event schema, strips unknown fields, rejects malformed events
- **Storage:** Pluggable store backends (in-memory for testing, JSON Lines for production)
- **Aggregation:** Rolls up events into time-windowed summaries (counts, durations, outcomes)
- **Export:** Produces aggregated output for downstream consumers

Storage is bounded. Events are immutable after ingestion. Configuration is frozen after startup.

## Non-Goals

This repo intentionally does not:

- Serve as an MCP server (upstream repos own their MCP layers)
- Provide a dashboard or visualization layer
- Collect or store PII in any form
- Normalize transcripts (that is `wild-transcript-pipeline`)
- Perform gap analysis (that is `wild-gap-miner`)
- Act as a generic event bus or message broker
- Replace per-repo audit trails (audit logs remain authoritative; telemetry is a derived, sparse view)
- Support real-time streaming or pub/sub delivery

## Canonical Docs

| Doc | Purpose |
|-----|---------|
| `000-docs/001-PP-PLAN-repo-blueprint.md` | Mission, boundaries, architecture direction |
| `000-docs/002-PP-PLAN-epic-build-plan.md` | 10-epic build plan with sequencing and dependencies |
| `000-docs/003-TQ-STND-privacy-model.md` | Privacy specification — what is collected, what is excluded, enforcement rules |
| `000-docs/004-TQ-STND-event-schema.md` | Event envelope, per-type metadata schemas, validation rules |
| `000-docs/005-AT-ADEC-storage-architecture.md` | Store layer design, bounding strategy, pluggable backends |
| `000-docs/006-AT-ADEC-aggregation-export.md` | Aggregation windows, export format, downstream contract |
| `000-docs/007-AT-ADEC-integration-pattern.md` | Subscriber interface, hook wiring, failure isolation |

## Development

```bash
bundle install          # Install dependencies
bundle exec rspec       # Run test suite
bundle exec rubocop     # Lint
```

## License

Intent Solutions Proprietary. See [LICENSE](LICENSE) for details.
