# wild-session-telemetry — 10-Epic Build Plan

**Document type:** Canonical repo build plan
**Filed as:** `002-PP-PLAN-epic-build-plan.md`
**Repo:** `wild-session-telemetry`
**Status:** Active — Phase 0 planning
**Last updated:** 2026-03-19
**Blueprint reference:** `001-PP-PLAN-repo-blueprint.md`

---

## 1. Purpose

This is the canonical 10-epic build plan for `wild-session-telemetry`.

It translates the repo blueprint into an implementation-ready execution story. This document is not Beads. It is not code. It is the structured, narrative planning layer between the blueprint (what we are building and why) and Beads (how we track doing it). When Beads are created, they must be faithful to this plan.

---

## 2. Planning Intent

The blueprint defines what this library is and what it must not become. This plan defines the order in which it gets built, why that order is correct, and what each phase must produce before the next phase starts.

The plan is written for two audiences:

**Future Claude Code sessions** — who need to understand the build narrative before touching code, and who must resist the temptation to skip ahead.

**The operator (Jeremy)** — who needs to be able to open this document at any point and understand exactly where the repo is in its story.

Every epic here earns the right to exist. The ordering is not arbitrary.

---

## 3. Sequencing Logic

The build sequence follows a principle specific to data pipelines: **prove the data is clean before you do anything with it.**

The stack is built from the ground up:

1. **Epics 1-2: Foundation** — Build the ingestion boundary and durable storage. Until events can be received, validated, and stored, nothing else matters.
2. **Epic 3: Privacy hardening** — Prove that the privacy model works under adversarial conditions. This must happen before any data reaches export or aggregation. If the privacy filter leaks, everything downstream is contaminated.
3. **Epic 4: Export pipeline** — Build the stable output contract for downstream consumers. This is the primary external interface and must be versioned and documented before gap-miner integrates.
4. **Epics 5-6: Value extraction** — Aggregation and pattern detection. These are the features that make telemetry useful beyond raw event storage. They depend on clean, validated, durably stored data.
5. **Epic 7: Integration testing** — End-to-end proof that the complete pipeline works from HookEmitter to export.
6. **Epic 8: Adversarial testing** — Prove every safety and privacy claim with tests designed to break the system.
7. **Epic 9: Operator documentation** — Configuration reference, deployment guide, workflow guide.
8. **Epic 10: Expansion readiness** — v2 roadmap, extension points, out-of-scope confirmation.

This order is not negotiable. You cannot aggregate dirty data. You cannot export data you have not validated. You cannot document a system that is not built.

---

## 4. Dependency Map

### Internal dependencies (within this repo)

```
Epic 1 (Foundation + Event Receiver)
  |
  v
Epic 2 (Durable Storage) ---- depends on Epic 1 store interface
  |
  v
Epic 3 (Privacy Hardening) -- depends on Epic 1 schema validation + Epic 2 storage
  |
  v
Epic 4 (Export Pipeline) ---- depends on Epic 3 clean data guarantee
  |
  v
Epic 5 (Aggregation) ------- depends on Epic 4 export format + Epic 2 query interface
  |
  v
Epic 6 (Pattern Detection) - depends on Epic 5 aggregation + Epic 2 query interface
  |
  v
Epic 7 (Integration Testing) depends on Epics 1-6 complete
  |
  v
Epic 8 (Adversarial Testing) depends on Epic 7 integration proof
  |
  v
Epic 9 (Operator Docs) ----- depends on Epics 1-8 stable interfaces
  |
  v
Epic 10 (Expansion Readiness) depends on Epic 9 documentation complete
```

### Cross-repo dependencies

| Dependency | Source | Target | Nature |
|-----------|--------|--------|--------|
| Event schema | `wild-admin-tools-mcp` doc 018 | Epic 1 schema validator | Schema contract — telemetry validates against the envelope schema defined by admin-tools-mcp |
| HookEmitter interface | `wild-admin-tools-mcp` doc 018 | Epic 1 event receiver | Subscriber contract — `receive(event)` interface must match HookEmitter's expectations |
| Export contract | Epic 4 export pipeline | `wild-gap-miner` | Output contract — gap-miner consumes telemetry exports; schema must be stable before gap-miner integrates |

---

## 5. The Epics

### Epic 1: Foundation + Event Receiver

**Mission:** Build the gem scaffold and the core ingestion boundary — the `receive(event)` interface, schema validation, and in-memory storage — so that events from admin-tools-mcp can be received, validated, and stored in a running Ruby process.

**Why this is first:** Nothing else in this repo works without a working ingestion path. The event receiver is the entry point. Schema validation is the first line of defense. MemoryStore is the simplest possible storage backend. Together they prove that the core pipeline functions before we add durability, privacy hardening, or export.

**What it delivers:**

- Gem scaffold: gemspec, Gemfile, directory structure, RSpec configuration, `WildSessionTelemetry` namespace
- `EventReceiver` class implementing the `receive(event)` subscriber interface
- `SchemaValidator` class that validates events against the known envelope schema (required fields, field types, known event types, known outcome values)
- `MemoryStore` class that stores validated events in-process with basic query support (by event_type, by time range, by caller_id)
- `Configuration` class with startup-only configuration (store backend, retention window, size limits)
- Fire-and-forget error handling — no exception escapes `receive(event)`
- Unit tests for validation (valid events, missing fields, unknown types, malformed data)
- Unit tests for MemoryStore (store, query, count, purge)

**Key acceptance criteria:**

- [ ] `WildSessionTelemetry::EventReceiver.new(config).receive(event)` accepts a valid event hash and stores it
- [ ] Invalid events (missing fields, unknown types, wrong types) are silently rejected
- [ ] `MemoryStore` supports query by event_type, time range, and caller_id
- [ ] No exception from the telemetry system propagates to the caller of `receive(event)`
- [ ] Configuration is frozen after initialization — no runtime changes
- [ ] All tests pass

**Dependencies:** None (first epic). Requires admin-tools-mcp doc 018 event schema as reference (already available).

---

### Epic 2: Durable Storage

**Mission:** Add persistent storage via JsonLinesStore so that telemetry data survives process restarts, and implement retention management so that storage does not grow without bound.

**Why this is second:** MemoryStore proves the ingestion path works. JsonLinesStore makes it durable. Without durable storage, telemetry is lost on every process restart. Without retention management, storage grows until it becomes an operational problem.

**What it delivers:**

- `JsonLinesStore` class that writes validated events as append-only JSON Lines files
- File rotation support (configurable file size or time-based rotation)
- Retention management: automatic purge of events older than the configurable retention window (default 90 days)
- Storage size monitoring: track current storage size, configurable size limit with automatic oldest-first purge when limit is exceeded
- Query support on JsonLinesStore: by event_type, time range, caller_id (sequential scan with filtering — not indexed, acceptable for v1 volumes)
- Common store interface extracted: both MemoryStore and JsonLinesStore implement the same `store(event)`, `query(filters)`, `purge(before:)`, `size` interface
- Concurrent write safety: file-level locking for JsonLinesStore writes
- Unit tests for JsonLinesStore (write, read, rotate, purge, size limits)
- Unit tests for retention management (time-based purge, size-based purge)

**Key acceptance criteria:**

- [ ] Events written to JsonLinesStore survive process restart (read back after re-instantiation)
- [ ] Retention purge removes events older than the configured window
- [ ] Size limit enforcement prevents storage from exceeding the configured maximum
- [ ] File rotation creates new files when the current file exceeds the configured size
- [ ] Concurrent writes do not corrupt data (file locking)
- [ ] MemoryStore and JsonLinesStore are interchangeable via the common store interface
- [ ] All tests pass

**Dependencies:** Epic 1 (store interface, event format, configuration).

---

### Epic 3: Privacy Hardening

**Mission:** Implement and prove the per-event-type metadata validation and field stripping that ensures no forbidden data reaches storage, even under adversarial input conditions.

**Why this is third:** Epics 1 and 2 established ingestion and storage. Before any data flows to export or aggregation, we must prove that the privacy model works. If the privacy filter leaks forbidden data into storage, every downstream consumer inherits that leak. This epic is the firewall.

**What it delivers:**

- `PrivacyFilter` class that strips globally forbidden fields (raw parameter values, before/after snapshots, nonce values, stack traces, adapter-specific identifiers) from all events
- Per-event-type metadata allowlisting:
  - `action.completed`: allows only `category`, `operation`, `phase`, `denial_reason`, `blast_radius_count`, `confirmation_used`
  - `gate.evaluated`: allows only `gate_result`, `capability_checked`
  - `rate_limit.checked`: allows only `rate_result`, `current_count`, `limit`, `window_seconds`
- Integration of PrivacyFilter into the EventReceiver pipeline (validate -> filter -> store)
- Adversarial privacy tests:
  - Event with forbidden metadata keys (e.g., `params`, `before_state`, `after_state`, `nonce`, `stack_trace`, `adapter_id`) — verify they are stripped
  - Event with unknown metadata keys not on any allowlist — verify they are stripped
  - Event with deeply nested metadata attempting to smuggle forbidden data — verify nested structures are handled
  - Event with metadata key that matches an allowlisted name but contains embedded forbidden data in its value — verify values are not inspected (allowlisting is by key, not value content)
- Documentation of the privacy filter's design decisions and limitations

**Key acceptance criteria:**

- [ ] No forbidden field survives to storage, regardless of input
- [ ] Per-event-type allowlists are enforced — unknown metadata keys are stripped
- [ ] Adversarial tests pass: forbidden data in various positions and formats is stripped
- [ ] The privacy filter operates in the ingestion path, not as a post-hoc cleanup
- [ ] Privacy exclusions are hardcoded, not configurable (safety invariant)
- [ ] All tests pass

**Dependencies:** Epic 1 (EventReceiver, SchemaValidator), Epic 2 (store interface for integration testing).

---

### Epic 4: Export Pipeline

**Mission:** Build the stable, versioned output contract that downstream consumers (primarily gap-miner) depend on, and implement the JSON Lines export pipeline that transforms stored events into the documented output format.

**Why this is fourth:** The export pipeline is the primary external interface. It must be built on top of clean, validated, privacy-filtered data (Epics 1-3). The export contract must be stable and versioned because downstream consumers will depend on it. Getting this right before building aggregation (Epic 5) ensures that aggregation output has a clear home in the export format.

**What it delivers:**

- Export schema definition: versioned JSON schema for the export format
- `Exporter` class that transforms stored events into the export format
- JSON Lines export output: one JSON object per line, with schema version header
- Export content types:
  - Raw validated events (with privacy-filtered metadata)
  - Session summaries (events grouped by caller_id and time window)
  - Tool utilization records (per-action invocation counts)
  - Outcome distribution records (per-action outcome breakdowns)
  - Pattern records (placeholder for Epic 6)
- Schema versioning: semver for export schemas; breaking changes require major version bump
- Export filtering: by time range, by event type, by caller_id
- Unit tests for export format (schema compliance, version header, filtering)
- Integration tests (store events -> export -> verify output matches contract)

**Key acceptance criteria:**

- [ ] Export output is valid JSON Lines with a schema version header
- [ ] Export schema is documented and versioned
- [ ] Export content includes raw events, session summaries, utilization, and outcome distributions
- [ ] Export filtering by time range, event type, and caller_id works correctly
- [ ] Internal storage format changes do not break the export contract (export transforms, not passes through)
- [ ] All tests pass

**Dependencies:** Epics 1-3 (clean, validated, privacy-filtered data in storage).

---

### Epic 5: Aggregation

**Mission:** Build the aggregation engine that computes session summaries, tool utilization metrics, outcome distributions, and latency statistics from stored events, providing the operational insight that makes telemetry useful beyond raw event storage.

**Why this is fifth:** Aggregation requires clean data (Epics 1-3) and an export format to target (Epic 4). Aggregation is the feature that transforms raw event collection into actionable operational intelligence. Without it, the telemetry layer is just a log file with a schema.

**What it delivers:**

- `Aggregator` class with pluggable aggregation strategies
- Session summaries: events grouped by caller_id and configurable time window, with event counts, distinct actions, outcome breakdown, and total duration
- Tool utilization: per-action invocation counts, unique caller counts, success rate, average duration
- Outcome distributions: per-action breakdown of outcomes (success, denied, error, preview, rate_limited) with counts and percentages
- Latency statistics: per-action p50, p95, p99 duration_ms computed from stored events
- Time-windowed aggregation: all aggregations support configurable time windows (last hour, last day, last week, custom range)
- Minimum population thresholds: aggregations with fewer than a configurable minimum number of events are suppressed to prevent re-identification
- Integration with export pipeline: aggregation results flow into the export format as typed records
- Unit tests for each aggregation type (known input -> expected output)
- Edge case tests (empty data, single event, single caller, time window boundaries)

**Key acceptance criteria:**

- [ ] Session summaries correctly group events by caller_id and time window
- [ ] Tool utilization correctly computes per-action metrics
- [ ] Outcome distributions correctly break down outcomes per action
- [ ] Latency statistics correctly compute p50, p95, p99
- [ ] Minimum population thresholds suppress small-population aggregations
- [ ] Aggregation results integrate into the export pipeline
- [ ] All tests pass

**Dependencies:** Epics 1-3 (clean stored data), Epic 4 (export format for aggregation output).

---

### Epic 6: Pattern Detection

**Mission:** Analyze stored events for sequential tool call patterns, failure cascades, and common usage sequences that provide insight into how agents and operators use administrative tools over time.

**Why this is sixth:** Pattern detection is the most analytically sophisticated feature. It requires clean stored data (Epics 1-3), an export format (Epic 4), and aggregation foundations (Epic 5). Patterns are the highest-value output for gap-miner — they reveal not just what happened, but what happened in sequence and what sequences suggest about missing capabilities or broken workflows.

**What it delivers:**

- `PatternDetector` class that analyzes stored events for sequential patterns
- Sequential tool call analysis: identify common action sequences within sessions (e.g., "inspect job -> retry job -> inspect job" is a common pattern)
- Failure cascade detection: identify sequences where one failure leads to subsequent failures (e.g., gate denial -> repeated retry attempts -> rate limit hit)
- Common pattern catalog: identify and count the most frequent action sequences across all sessions
- Pattern records: structured output format for detected patterns, integrated into the export pipeline
- Configurable pattern parameters: minimum sequence length, minimum occurrence count, time window for session grouping
- Unit tests for pattern detection (known sequences -> expected patterns)
- Edge case tests (no patterns, single-event sessions, overlapping sequences)

**Key acceptance criteria:**

- [ ] Sequential patterns are correctly identified from stored events
- [ ] Failure cascades are detected when one failure precedes subsequent failures
- [ ] Common patterns are ranked by frequency
- [ ] Pattern records integrate into the export pipeline
- [ ] Pattern detection handles edge cases (empty data, very long sessions, concurrent sessions)
- [ ] All tests pass

**Dependencies:** Epics 1-3 (stored data), Epic 4 (export format), Epic 5 (aggregation concepts and time windowing).

---

### Epic 7: Integration Testing

**Mission:** Prove end-to-end that the complete telemetry pipeline works from admin-tools-mcp HookEmitter event emission through EventReceiver ingestion, privacy filtering, durable storage, aggregation, pattern detection, and export — as a single coherent flow.

**Why this is seventh:** All individual components have been built and unit-tested in Epics 1-6. Integration testing proves they work together. This is the "does the whole thing actually work?" epic. It catches interface mismatches, data format inconsistencies, and pipeline failures that unit tests miss.

**What it delivers:**

- End-to-end integration test: emit events through a simulated HookEmitter -> receive via EventReceiver -> validate -> filter -> store in JsonLinesStore -> aggregate -> detect patterns -> export -> verify output
- Multi-event-type integration: test the full pipeline with all three event types (`action.completed`, `gate.evaluated`, `rate_limit.checked`) in realistic proportions
- Realistic event volume tests: process hundreds of events through the full pipeline and verify correctness of aggregations and patterns
- Retention integration: store events, advance time, verify purge works correctly across the full pipeline
- Error path integration: inject invalid events, malformed data, and storage failures; verify the pipeline degrades gracefully (fire-and-forget, no propagation)
- Export contract verification: verify that the exported data matches the documented schema exactly
- Cross-component interface verification: verify that every component's output is valid input for the next component

**Key acceptance criteria:**

- [ ] End-to-end test passes: events in -> validated export out
- [ ] All three event types flow correctly through the complete pipeline
- [ ] Aggregations computed from integration test data are mathematically correct
- [ ] Pattern detection finds expected patterns in integration test data
- [ ] Retention purge works correctly in the integrated pipeline
- [ ] Error injection does not break the pipeline or propagate to callers
- [ ] Export output matches the documented schema contract
- [ ] All tests pass

**Dependencies:** Epics 1-6 (all components built).

---

### Epic 8: Adversarial Testing

**Mission:** Prove every safety and privacy claim made in the blueprint, safety model, and privacy model with adversarial tests specifically designed to break those claims. If a claim cannot be tested adversarially, it is not a real safety guarantee.

**Why this is eighth:** Adversarial testing is the verification layer. It comes after integration testing (Epic 7) because it needs a working system to attack. The goal is not to find bugs in individual components (unit tests do that) — the goal is to prove that the system-level safety properties hold under malicious input, unusual conditions, and edge cases.

**What it delivers:**

- Privacy adversarial tests:
  - Attempt to smuggle forbidden data through metadata fields
  - Attempt to bypass per-type allowlists with edge-case key names
  - Attempt to reconstruct private data from aggregation output
  - Attempt to infer caller identity from small-population aggregations
- Storage adversarial tests:
  - Attempt to exceed storage limits through rapid high-volume event injection
  - Attempt to corrupt stored data through malformed events
  - Attempt to cause unbounded memory growth through MemoryStore abuse
  - Attempt to fill disk through JsonLinesStore without triggering size limits
- Schema adversarial tests:
  - Attempt to inject unexpected types into validated fields
  - Attempt to pass events with extra fields that bypass validation
  - Attempt to exploit schema validation edge cases (empty strings, null values, extreme numeric values)
- Configuration adversarial tests:
  - Attempt to modify configuration after startup
  - Attempt to disable privacy filtering through configuration
  - Attempt to override hardcoded safety invariants
- Export adversarial tests:
  - Attempt to cause export to leak internal storage format details
  - Attempt to cause export schema version mismatch

**Key acceptance criteria:**

- [ ] Every privacy claim in `003-TQ-STND-privacy-model.md` has at least one adversarial test
- [ ] Every safety rule in `005-TQ-STND-safety-model.md` has at least one adversarial test
- [ ] Every threat in `006-AT-ADEC-threat-model.md` has at least one adversarial test
- [ ] No adversarial test succeeds in breaking a claimed safety property
- [ ] Adversarial test coverage is documented and mapped to claims
- [ ] All tests pass

**Dependencies:** Epic 7 (working integrated system to test against).

---

### Epic 9: Operator Docs

**Mission:** Produce the documentation that an operator needs to deploy, configure, and operate the telemetry library in a real environment — configuration reference, deployment guide, and workflow guide.

**Why this is ninth:** Documentation is written after the system is built and tested, not before. Writing docs for an unbuilt system produces fiction. Writing docs after adversarial testing (Epic 8) ensures the documented behavior is the verified behavior.

**What it delivers:**

- Configuration reference: every configurable parameter, its type, default value, valid range, and effect
- Deployment guide: how to add the gem to a project, configure it, attach it to admin-tools-mcp's HookEmitter, set up durable storage, and verify it is working
- Workflow guide: common operational tasks — checking telemetry health, querying stored events, running exports, interpreting aggregations, managing retention
- Troubleshooting guide: common problems and their solutions — events not being stored, storage growing unexpectedly, export format mismatches
- Updated CLAUDE.md with build commands, directory layout, testing approach, and safety rules specific to this repo
- Updated README.md with installation, quick start, and architecture overview

**Key acceptance criteria:**

- [ ] Configuration reference covers every parameter
- [ ] Deployment guide is sufficient for a new operator to integrate the library
- [ ] Workflow guide covers the most common operational tasks
- [ ] CLAUDE.md is updated with repo-specific instructions
- [ ] README.md provides a clear, concise overview
- [ ] All documentation references verified behavior (not aspirational behavior)

**Dependencies:** Epics 1-8 (stable, tested system).

---

### Epic 10: Expansion Readiness

**Mission:** Confirm the v1 scope is complete, document what is explicitly out of scope, identify extension points for v2, and prepare the repo for handoff to ongoing maintenance and evolution.

**Why this is last:** Expansion readiness is the capstone. It confirms that v1 is done, documents what v1 is not, and leaves clear signposts for future work. Doing this last ensures the v2 roadmap is grounded in the reality of what v1 actually delivered, not in pre-implementation aspirations.

**What it delivers:**

- v1 completion checklist: every epic's acceptance criteria verified
- v2 roadmap document: prioritized list of features, improvements, and extensions for v2
  - Potential v2 features: indexed query support, streaming export, additional event sources, custom aggregation strategies, cross-session pattern analysis, real-time alerting hooks
- Extension point documentation: where and how the library is designed to be extended
  - Store interface for custom storage backends
  - Aggregation strategy interface for custom aggregations
  - Pattern detector interface for custom pattern analysis
  - Export format for additional output formats
- Out-of-scope confirmation: explicit restatement of non-goals from the blueprint with confirmation that they remain out of scope
- Dependency documentation: current state of cross-repo dependencies and any coordination needed for v2
- Release preparation: version tagging, changelog, gem publishing readiness

**Key acceptance criteria:**

- [ ] Every epic's acceptance criteria is verified complete
- [ ] v2 roadmap is documented and prioritized
- [ ] Extension points are documented with interface contracts
- [ ] Non-goals are confirmed as still out of scope
- [ ] Repo is ready for v1 release (version tag, changelog, clean test suite)
- [ ] All tests pass

**Dependencies:** Epics 1-9 (everything complete).

---

## 6. Epic Summary Table

| # | Title | Mission (one line) | Key dependency |
|---|-------|--------------------|----------------|
| 1 | Foundation + Event Receiver | Gem scaffold + receive(event) + schema validation + MemoryStore | None |
| 2 | Durable Storage | JsonLinesStore + retention management + size monitoring | Epic 1 |
| 3 | Privacy Hardening | Per-type metadata validation + adversarial privacy tests | Epics 1-2 |
| 4 | Export Pipeline | Stable versioned output contract for gap-miner | Epics 1-3 |
| 5 | Aggregation | Session summaries, tool utilization, outcome distributions, latency stats | Epics 1-4 |
| 6 | Pattern Detection | Sequential analysis, failure cascades, common patterns | Epics 1-5 |
| 7 | Integration Testing | End-to-end pipeline proof | Epics 1-6 |
| 8 | Adversarial Testing | Prove every safety/privacy claim | Epic 7 |
| 9 | Operator Docs | Configuration reference, deployment guide, workflow guide | Epics 1-8 |
| 10 | Expansion Readiness | v2 roadmap, extension points, out-of-scope confirmation | Epics 1-9 |

---

## 7. Current Status

This plan is complete. No epics have been started. The next step is Beads creation and operator review.
