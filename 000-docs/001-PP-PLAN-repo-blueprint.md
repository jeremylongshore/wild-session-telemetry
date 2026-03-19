# wild-session-telemetry — Repo Blueprint

**Document type:** Canonical repo blueprint
**Filed as:** `001-PP-PLAN-repo-blueprint.md`
**Repo:** `wild-session-telemetry`
**Status:** Active — Phase 0 planning
**Last updated:** 2026-03-19

---

## 1. Purpose

This is the canonical blueprint for `wild-session-telemetry`.

It defines the repo mission, product vision, non-goals, architecture direction, privacy model, and planning expectations before any implementation begins. It is the source of truth for what this repo is, what it will do, and what it will not do.

This document is written for future Claude Code sessions and for the operator. It is not an implementation spec. It is not the epic breakdown. It is the authoritative pre-implementation reference that all later planning and execution must align with.

This repo builds on patterns established by `wild-admin-tools-mcp` — specifically the flat namespace convention, the MemoryStore/JsonLinesStore storage approach, and the structured event model defined in doc 018. However, the fundamental challenge here is different: where admin-tools-mcp governs mutation, this repo governs observation. The safety model is not about preventing unauthorized writes — it is about ensuring that the telemetry collected never leaks private data, never grows without bounds, and never couples downstream consumers to internal storage details.

---

## 2. Repo Mission

`wild-session-telemetry` provides **privacy-aware telemetry collection and export for agent session operations within the wild ecosystem**.

It is a pure Ruby library gem that ingests structured operational events emitted by upstream services (primarily `wild-admin-tools-mcp` via its HookEmitter interface), validates those events against known schemas, strips forbidden data, stores events durably, computes aggregations, and exports structured summaries for downstream consumers — most immediately `wild-gap-miner`.

The repo exists because there is currently no structured way to capture, validate, and persist operational telemetry from the admin-tools-mcp pipeline. Admin-tools-mcp emits events through its hook system, but without a subscriber those events disappear. Operators have no visibility into tool utilization patterns, failure rates, latency distributions, or sequential usage patterns. Gap-miner has no structured input to work from. This repo closes that gap.

The library is consumed as a gem dependency. It is not a server, not an MCP endpoint, and not a standalone process. The consuming application (or a lightweight runner) instantiates the telemetry system, subscribes to event sources, and queries the stored data or triggers exports. The library does the rest.

---

## 3. Problem Statement

The wild ecosystem's admin-tools-mcp server produces a stream of structured operational events — actions completed, capability gates evaluated, rate limits checked — through its HookEmitter interface (doc 018). Today, those events have no durable subscriber.

This creates several concrete problems:

**No operational visibility.** When an operator asks "how often do agents retry failed jobs?" or "what percentage of gate evaluations result in denial?", the answer is "we don't know." The events exist momentarily in the hook pipeline and then vanish. There is no historical record and no way to answer aggregate questions about operational patterns.

**No input for gap analysis.** The `wild-gap-miner` repo is designed to identify gaps in agent capabilities and operational workflows. It needs structured telemetry data as input — tool utilization summaries, failure distributions, sequential action patterns. Without a telemetry layer that collects and normalizes this data, gap-miner has nothing to analyze.

**No privacy enforcement at the collection boundary.** Admin-tools-mcp events may carry metadata that varies by event type. Some metadata fields are operationally valuable (outcome, duration, category). Others could leak private information if collected indiscriminately (raw parameter values, before/after snapshots, adapter-specific identifiers). Without a telemetry layer that validates metadata against per-event-type allowlists and strips forbidden fields, any downstream consumer that naively stores raw events risks accumulating private data.

**No retention or storage management.** Without a managed storage layer, any ad-hoc event collection (log files, append-only dumps) grows without bound. There is no retention policy, no automatic purge, no size monitoring. Over time this becomes an operational liability — storage costs grow, queries slow down, and the data becomes a compliance risk if it contains anything that should have been purged.

**No stable output contract for downstream consumers.** Even if events were collected ad-hoc, downstream consumers like gap-miner would need to parse raw event formats, handle schema changes, and deal with missing or malformed data. A telemetry layer provides a stable, versioned output contract: "here is what you can expect from the export, here is the schema version, here is what changed." This decouples consumers from the raw event format and allows the telemetry layer to evolve its internal storage independently.

---

## 4. Core Product Vision

The intended product is a pure Ruby library gem that provides the complete telemetry lifecycle: ingestion, validation, privacy enforcement, durable storage, aggregation, and export.

**Ingestion via subscriber interface.**
The library exposes a `receive(event)` method that conforms to the subscriber contract defined in admin-tools-mcp doc 018. Any HookEmitter-compatible source can attach this subscriber. The subscriber validates the event, strips forbidden data, and stores the clean event. Ingestion is fire-and-forget: if the telemetry system fails to process an event, the failure never propagates to the caller. The hook pipeline must never be blocked or broken by telemetry.

**Schema validation at the ingestion boundary.**
Every incoming event is validated against the known event envelope schema: `event_type`, `timestamp`, `caller_id`, `action`, `outcome`, `duration_ms`, and `metadata`. Unknown event types are rejected. Known event types have their metadata validated against per-type allowlists. Invalid events are silently dropped — they do not error, they do not propagate, they are simply not stored. This is the first line of defense against schema drift and malformed data.

**Privacy enforcement through field-level filtering.**
Before any event reaches storage, the library strips fields that are explicitly forbidden: raw parameter values, before/after snapshots, nonce values, stack traces, and adapter-specific identifiers. This is not optional. It is not configurable. The privacy exclusions are hardcoded as a safety invariant. Additionally, per-event-type metadata is validated against an allowlist of known fields — any metadata key not on the allowlist for that event type is stripped. Defense in depth: even if the upstream source includes a forbidden field, the telemetry layer removes it before storage.

**Durable storage with retention management.**
Events are stored durably via a pluggable store interface. Two implementations ship in v1: `MemoryStore` (in-process, for testing and lightweight use) and `JsonLinesStore` (append-only JSON Lines files, for durable persistence). Both stores support configurable retention windows (default 90 days) and automatic purge of expired events. `JsonLinesStore` additionally supports storage size monitoring and configurable size limits to prevent unbounded disk growth.

**Aggregation for operational insight.**
The library computes aggregate summaries from stored events: session summaries (events grouped by caller and time window), tool utilization (which actions are used most, by whom), outcome distributions (success/denied/error/rate_limited rates per action), and latency statistics (p50, p95, p99 duration per action). Aggregations operate on clean, validated data and are designed to not enable re-identification of individual sessions from small populations.

**Export with stable output contract.**
The library exports data in versioned JSON Lines format with a documented schema. The export contract is the stable interface that downstream consumers (gap-miner, future analytics) depend on. Internal storage format changes do not break the export contract. Schema versions follow semver: breaking changes to the export schema require a major version bump.

---

## 5. Non-Goals and Boundaries

These boundaries exist to keep the repo focused. Every item here is a deliberate exclusion, not an oversight.

**Not transcript normalization.**
This repo collects structured operational events, not raw agent transcripts. Transcript ingestion, normalization, and processing belong in `wild-transcript-pipeline`. The events this repo handles are already structured — they have defined schemas, typed fields, and known event types. There is no free-text parsing, no natural language processing, and no transcript format handling.

**Not gap analysis.**
This repo collects, stores, and exports telemetry data. It does not analyze that data for capability gaps, workflow deficiencies, or improvement opportunities. Gap analysis belongs in `wild-gap-miner`, which consumes this repo's export as input. The boundary is clean: this repo answers "what happened?"; gap-miner answers "what should we do about it?"

**Not an MCP server.**
This is a pure library gem consumed as a dependency. It does not expose an MCP interface. It does not handle MCP protocol messages. It does not register tools. It is not a standalone server process. Consumers integrate it by requiring the gem and calling Ruby methods.

**Not a real-time streaming platform.**
Events are processed and stored when received. There is no pub/sub, no websocket streaming, no real-time notification system, and no event bus. The library is synchronous and single-process. If a consumer needs real-time event streaming, that is a different system.

**Not a dashboard.**
This repo does not provide any user interface — no web UI, no CLI visualization, no charts, no graphs. It provides data. Consumers build their own interfaces on top of the export contract.

**Not PII collection.**
The privacy model is explicit: this repo collects operational metadata, not personally identifiable information. The privacy exclusions (raw parameters, snapshots, nonces, stack traces, adapter identifiers) are designed to ensure that no PII enters the telemetry store. If a future event source emits PII in a metadata field, the per-type allowlist blocks it.

**Not a replacement for per-repo audit trails.**
Admin-tools-mcp has its own audit trail that captures detailed mutation records with before/after state snapshots. This telemetry repo does not replace or duplicate that audit trail. It captures a separate, coarser signal: operational metadata about what happened, not the full forensic record of what changed. The audit trail is for forensics; the telemetry is for patterns.

**Not a generic event bus.**
This repo handles three known event types from a known upstream source. It is not a general-purpose event ingestion system. It does not support arbitrary event schemas, dynamic event type registration, or pluggable upstream sources. If the ecosystem needs a generic event bus, that is a different repo.

---

## 6. Primary Users and Use Cases

### Users

**Operators** — who need aggregate visibility into how administrative tools are being used in production. "How many job retries happened this week?" "What percentage of gate checks are denied?" "Which actions have the highest latency?" Operators use this data to tune rate limits, adjust blast radius caps, and identify operational patterns that suggest configuration changes.

**`wild-gap-miner`** — the primary downstream consumer. Gap-miner ingests session telemetry exports to identify: which tools agents attempt to use but fail, which actions are denied most often, where agents abandon workflows, and what sequential patterns suggest missing capabilities. Gap-miner depends on the export contract, not on internal storage details.

**Future analytics consumers** — other wild ecosystem repos or external tools that need structured operational data. The versioned export contract is designed to support consumers that do not exist yet without requiring telemetry layer changes.

### High-value early use cases

1. **Collect and persist operational events from admin-tools-mcp** — the HookEmitter emits events for every action, gate evaluation, and rate limit check. The telemetry subscriber captures these events, validates them, strips forbidden data, and stores them durably.

2. **Export structured session summaries for gap-miner** — gap-miner needs to know: what tools were used in each session, what outcomes occurred, and in what sequence. The telemetry export provides this as versioned JSON Lines.

3. **Compute tool utilization metrics** — the operator asks "which admin tools are used most?" The telemetry aggregation layer answers with per-action invocation counts, success rates, and latency distributions.

4. **Enforce privacy at the collection boundary** — admin-tools-mcp events may carry metadata that includes operationally useful fields alongside potentially sensitive fields. The telemetry layer's per-type allowlists ensure only approved metadata reaches storage.

5. **Manage storage lifecycle** — events accumulate over time. The retention management subsystem automatically purges events older than the configurable retention window and monitors storage size against configurable limits.

6. **Detect operational patterns** — sequential analysis reveals common tool call sequences, failure cascades (action A fails, leading to action B, which also fails), and usage patterns that suggest workflow improvements.

---

## 7. Early Architecture Direction

This section describes the expected shape of the system. It is directional — not a final design. Decisions will be refined during the epic breakdown.

### Major components

**Event receiver**
The ingestion boundary. Implements the `receive(event)` subscriber interface from admin-tools-mcp doc 018. Responsible for: accepting incoming events, validating the event envelope schema, dispatching to the privacy filter, and forwarding clean events to the store. Fire-and-forget semantics — any failure in the receiver is swallowed, never propagated to the caller.

**Schema validator**
Validates incoming events against the known envelope schema and per-event-type metadata allowlists. Rejects events with: missing required fields, unknown event types, invalid field types, or metadata keys not on the allowlist for the event type. Validation is strict at ingestion and permissive at export (store what you validate, export what you have).

**Privacy filter**
Strips forbidden fields from events before storage. Operates in two layers: (1) global exclusions — raw parameter values, before/after snapshots, nonce values, stack traces, adapter-specific identifiers are stripped from all events regardless of type; (2) per-type metadata allowlisting — only metadata keys on the allowlist for the event type pass through, all others are stripped. The privacy filter is not configurable — the exclusions are hardcoded safety invariants.

**Store interface**
A pluggable storage abstraction with two v1 implementations:

- `MemoryStore` — in-process hash-based storage. Fast, ephemeral, suitable for testing and lightweight embedded use. Supports retention-based purge and event count limits.
- `JsonLinesStore` — append-only JSON Lines files on disk. Durable, queryable, suitable for production use. Supports retention-based purge, file rotation, and storage size monitoring.

Both stores implement a common interface: `store(event)`, `query(filters)`, `purge(before:)`, `size`.

**Aggregation engine**
Computes summaries from stored events. Aggregation types:

- Session summaries — events grouped by caller_id and configurable time window
- Tool utilization — per-action invocation counts and success rates
- Outcome distributions — per-action outcome breakdowns (success, denied, error, preview, rate_limited)
- Latency statistics — per-action p50, p95, p99 duration_ms

Aggregations are computed on demand from stored events, not maintained as running counters. This simplifies the storage model and ensures aggregations are always consistent with the underlying data.

**Export pipeline**
Produces versioned JSON Lines output for downstream consumers. The export schema is the stable contract. Internal storage format is an implementation detail. The export pipeline transforms stored events and computed aggregations into the documented output format. Schema versioning follows semver.

**Pattern detector**
Analyzes stored events for sequential patterns, failure cascades, and common tool call sequences. Pattern detection is a read-only analysis layer that operates on stored events. It does not modify stored data. Detected patterns are included in exports as pattern records.

### What this is not

Not a server. Not an MCP endpoint. Not a streaming platform. Not a dashboard. Not a generic event bus. Build the components above and ship something useful that connects admin-tools-mcp events to gap-miner analysis.

---

## 8. Privacy Model Summary

Privacy is the primary design constraint for this repo. The telemetry system sits at the boundary between operational event sources (which may emit rich data) and downstream consumers (which must receive only approved data). The privacy model ensures that the boundary filters correctly.

**Collected data (approved for storage):**
- `event_type` — one of the three known types
- `timestamp` — ISO 8601 event time
- `caller_id` — service account or operator identifier
- `action` — the operation name
- `outcome` — one of: success, denied, error, preview, rate_limited
- `duration_ms` — operation latency
- `metadata` — per-event-type approved fields only

**Excluded data (never stored, stripped at ingestion):**
- Raw parameter values from pipeline operations
- Before/after state snapshots
- Nonce values from confirmation protocols
- Stack traces from errors
- Adapter-specific identifiers

**Per-event-type metadata allowlists:**
- `action.completed`: category, operation, phase, denial_reason, blast_radius_count, confirmation_used
- `gate.evaluated`: gate_result, capability_checked
- `rate_limit.checked`: rate_result, current_count, limit, window_seconds

Any metadata key not on the allowlist for its event type is stripped before storage. This is defense in depth — even if the upstream source adds a new metadata field, it will not reach storage until the allowlist is explicitly updated.

The full privacy model is documented in `003-TQ-STND-privacy-model.md`.

---

## 9. Integration Points

**Upstream: `wild-admin-tools-mcp` HookEmitter (doc 018)**
The primary event source. Admin-tools-mcp defines three event types (`action.completed`, `gate.evaluated`, `rate_limit.checked`) and a common envelope schema. The telemetry subscriber attaches to the HookEmitter and receives events through the `receive(event)` interface. The event schema is defined by admin-tools-mcp — this repo validates against it but does not define it.

**Downstream: `wild-gap-miner`**
The primary consumer. Gap-miner ingests telemetry exports to identify capability gaps and workflow improvement opportunities. The export contract (versioned JSON Lines with session summaries, tool utilization, outcome distributions, and pattern records) is the interface between the two repos. Gap-miner depends on the export schema version, not on internal telemetry storage details.

**Potential future consumers:**
- `wild-skillops-registry` — could consume tool utilization data to inform capability registration
- `wild-hook-ops` — could consume event patterns to inform hook lifecycle management
- Custom operator dashboards — could consume export data for visualization

These are not v1 design constraints. The versioned export contract is designed to support them without requiring telemetry layer changes.

---

## 10. Risks and Design Tensions

**Schema drift.**
The event schema is defined by admin-tools-mcp. If admin-tools-mcp changes its event format — adds fields, renames fields, changes types — the telemetry validator may reject valid events or accept invalid ones. Mitigation: strict validation with clear error logging for rejected events; schema version tracking; coordination with admin-tools-mcp on schema changes.

**Unbounded storage growth.**
High-volume event streams can fill storage quickly. If retention purge is misconfigured or disabled, storage grows without bound. Mitigation: configurable retention windows with sensible defaults (90 days); configurable size limits on JsonLinesStore; automatic purge on write (opportunistic cleanup); monitoring hooks for storage size.

**Privacy leaks through metadata.**
If admin-tools-mcp adds a new metadata field that contains sensitive data, the per-type allowlist will strip it. But if someone updates the allowlist without reviewing the field's content, the sensitive data reaches storage. Mitigation: allowlists are hardcoded, not configurable; updating an allowlist requires a code change and review; adversarial tests specifically attempt to pass forbidden data through the pipeline.

**Export re-identification.**
Aggregations over small populations may enable re-identification. If only one caller uses a specific action, the per-action aggregation effectively identifies that caller. Mitigation: aggregations are designed for operational insight, not per-caller profiling; minimum population thresholds for aggregation output; documentation of this limitation.

**Fire-and-forget masking failures.**
The fire-and-forget ingestion model means that telemetry failures are silent. If the store is full, the validator has a bug, or the privacy filter is misconfigured, events are silently dropped. The caller never knows. Mitigation: internal error counting; health check interface that reports drop rates; periodic reconciliation between emitted events and stored events (not in v1, but the data model supports it).

**Downstream consumer coupling.**
If gap-miner or other consumers depend on internal storage details (file paths, storage format, field names) rather than the export contract, changes to the telemetry layer break consumers. Mitigation: the export contract is the only supported interface; internal storage format is explicitly undocumented and may change without notice; consumers that bypass the export contract do so at their own risk.

---

## 11. Documentation Needs

As implementation proceeds, this repo will need durable supporting documents beyond this blueprint. These should be created as needed and filed in `000-docs/` per `/doc-filing` conventions.

The initial document set (created alongside this blueprint):

| Document | Purpose |
|----------|---------|
| `002-PP-PLAN-epic-build-plan.md` | 10-epic build plan with sequencing and dependencies |
| `003-TQ-STND-privacy-model.md` | Full privacy specification: collected data, excluded data, per-type allowlists, retention, consent |
| `004-AT-STND-data-contracts.md` | Input contract, internal format, output contract, versioning |
| `005-TQ-STND-safety-model.md` | 8 privacy-focused safety rules |
| `006-AT-ADEC-threat-model.md` | 8 threats with mitigations |
| `007-AT-ADEC-architecture-decisions.md` | Key architecture decisions with rationale |

Anticipated future documents:

| Document | Purpose |
|----------|---------|
| Configuration reference | Every parameter, type, default, and constraint |
| Operator deployment guide | Setup, integration, and operational procedures |
| Export schema reference | Detailed export format documentation for downstream consumers |
| Pattern detection reference | Supported pattern types, detection algorithms, output format |

Create these docs when the work demands them. A doc that does not yet have a home in planned work belongs in `planning/notes.md` as a placeholder reference.

---

## 12. Planning and Task Model

Before implementation begins, this repo will receive the following planning artifacts in order:

1. **Repo build plan (10 epics)** — a human-readable breakdown of the full repo scope into 10 outcome-oriented epics
2. **Child tasks** — written in natural language, explaining the purpose of each unit of work
3. **Explicit dependency blocks** — between tasks within this repo and across repos where relevant
4. **Beads creation prompt** — a guided prompt for Claude Code to instantiate the full task structure
5. **Phased implementation prompts** — guided Claude Code prompts for executing each phase

No implementation begins before this planning structure is in place.

---

## 13. Current Status

This repo is in **blueprint and planning mode only**.

No application code exists. No Beads have been created. The GitHub repo has been initialized but contains only scaffold structure (CLAUDE.md, planning placeholders, license). No CI/CD has been configured.

This blueprint document is the first canonical planning artifact for the repo.

---

## 14. Immediate Next Step

The next planning steps for this repo are:

1. **Review and finalize the 10-epic build plan** (`002-PP-PLAN-epic-build-plan.md`)
2. **Review the supporting standards** (privacy model, data contracts, safety model, threat model, architecture decisions)
3. **Prepare the Beads creation prompt** for task instantiation
4. **Begin phased repo execution** — one epic at a time, with evidence-backed task closure

Do not begin implementation until the Beads structure is in place and the operator has reviewed the epic breakdown.
