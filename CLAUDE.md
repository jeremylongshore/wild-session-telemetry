# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Identity

- **Repo:** `wild-session-telemetry`
- **Ecosystem:** wild (see `../CLAUDE.md` for ecosystem-level rules)
- **Archetype:** B — Data Pipeline / Analytics
- **Mission:** Collect and export privacy-aware telemetry from agent sessions
- **Namespace:** `WildSessionTelemetry`
- **Language:** Ruby 3.2+, pure library gem (no MCP, no ActiveRecord)
- **Status:** v1 complete — all 10 epics implemented, 325 tests passing

## What This Repo Does

Provides a privacy-aware telemetry library that receives structured events from upstream operational repos (`wild-admin-tools-mcp`, `wild-rails-safe-introspection-mcp`), validates and stores them with strict privacy guarantees, aggregates them into time-windowed summaries, and exports aggregated data for downstream consumers (`wild-gap-miner`, `wild-transcript-pipeline`). The library operates as a subscriber — upstream emitters push events via fire-and-forget semantics.

## What This Repo Does NOT Do

- No MCP server (upstream repos own their MCP layers)
- No dashboard or visualization
- No PII collection or storage in any form
- No transcript normalization (that is `wild-transcript-pipeline`)
- No gap analysis (that is `wild-gap-miner`)
- No generic event bus or message broker functionality
- No replacement for per-repo audit trails (audit logs are authoritative; telemetry is derived)
- No real-time streaming or pub/sub delivery

## Directory Layout

```
lib/wild_session_telemetry/
  collector/            # EventReceiver — fire-and-forget ingestion
  privacy/              # Privacy::Filter — forbidden fields + metadata allowlisting
  schema/               # EventEnvelope + Validator
  store/                # MemoryStore, JsonLinesStore, RetentionManager, StorageMonitor
  aggregation/          # Engine (summaries, utilization, distributions, latency) + PatternDetector
  export/               # RecordBuilder + Exporter (JSON Lines output)
spec/
  wild_session_telemetry/  # Unit tests per module
  integration/             # Full pipeline integration tests
  adversarial/             # Privacy invariants, safety rules, threat mitigations
000-docs/               # Canonical docs per /doc-filing (12 documents)
```

## Build Commands

```bash
bundle install          # Install dependencies
bundle exec rspec       # Run test suite
bundle exec rubocop     # Lint
```

## Safety Rules for Claude Code

These are non-negotiable when working in this repo:

1. **Never store raw parameter values.** Telemetry events carry action names and outcomes, not the parameters that were passed to those actions. If a field contains user-supplied data, it must not enter the telemetry pipeline.
2. **Validate at the ingestion boundary.** Every event must be validated against the event schema before storage. Malformed events are rejected, not silently stored. No downstream code should assume events are valid — but all downstream code can rely on the ingestion boundary having enforced the schema.
3. **Strip unknown fields before storage.** Events arriving with fields not in the schema must have those fields removed before storage. Unknown fields are a PII leak vector.
4. **Bound storage growth.** Both MemoryStore and JsonLinesStore must enforce configurable size limits. No unbounded growth. When limits are reached, the oldest events are evicted or the store refuses new writes — never silently grows.
5. **Fire-and-forget semantics.** Telemetry failures must never propagate to the upstream caller. If ingestion, storage, or aggregation fails, the failure is logged to stderr and swallowed. The upstream pipeline must not be affected by telemetry being down, slow, or broken.
6. **Per-event-type metadata allowlisting.** Each event type has an explicit set of allowed metadata fields. Metadata fields not on the allowlist are stripped at ingestion. This prevents upstream code from smuggling arbitrary data through the metadata hash.
7. **No PII in aggregations.** Aggregated outputs must not contain caller IDs, action parameters, or any data that could identify a specific user or session. Aggregations produce counts, durations, and outcome distributions only.
8. **Immutable configuration after startup.** Once the telemetry client is configured and started, its configuration is frozen. No runtime reconfiguration of store backends, output paths, or privacy rules. This prevents configuration drift from weakening privacy guarantees mid-session.

## Key Canonical Docs

| Doc | Purpose |
|-----|---------|
| `000-docs/001-PP-PLAN-repo-blueprint.md` | Mission, boundaries, architecture direction |
| `000-docs/002-PP-PLAN-epic-build-plan.md` | 10-epic build plan with sequencing and dependencies |
| `000-docs/003-TQ-STND-privacy-model.md` | Privacy specification — what is collected, what is excluded |
| `000-docs/004-AT-STND-data-contracts.md` | Input/output contracts, export schema, versioning |
| `000-docs/005-TQ-STND-safety-model.md` | 8 enforceable safety rules |
| `000-docs/006-AT-ADEC-threat-model.md` | 8 threats with mitigations |
| `000-docs/007-AT-ADEC-architecture-decisions.md` | 7 key design decisions with rationale |
| `000-docs/008-DR-REFF-configuration-reference.md` | Every parameter, type, default, range |
| `000-docs/009-OD-OPNS-operator-deployment-guide.md` | Setup, configure, attach, verify |
| `000-docs/010-OD-GUID-operator-workflow-guide.md` | Health checks, querying, exports, retention |

## Task Tracking

Uses **Beads** (`bd`). All execution tracked repo-locally.

```bash
bd ready                # Find unblocked work
bd update <id> --claim  # Claim a task
bd close <id> --reason "evidence"  # Close with evidence
bd list                 # View all tasks
```

## Before Working Here

1. Read this file completely
2. Read the ecosystem CLAUDE.md at `../CLAUDE.md`
3. Check `bd ready` for current work state
4. Read the relevant canonical doc for the active epic
5. Do not skip ahead to later epics
