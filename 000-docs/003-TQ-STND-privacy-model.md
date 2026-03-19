# wild-session-telemetry — Privacy Model

**Document type:** Technical quality standard
**Filed as:** `003-TQ-STND-privacy-model.md`
**Repo:** `wild-session-telemetry`
**Status:** Active — Phase 0 planning
**Last updated:** 2026-03-19
**Blueprint reference:** `001-PP-PLAN-repo-blueprint.md`

---

## 1. Purpose

This document defines the complete privacy model for `wild-session-telemetry`. It specifies exactly what data is collected, what data is excluded, how exclusions are enforced, how data is retained, and how consent works.

This is a normative standard. Implementation must conform to this specification. Every claim in this document must be provable through tests (Epic 8, adversarial testing). If the implementation diverges from this spec, the implementation is wrong.

---

## 2. Data Classification

All data handled by this library is classified as **operational metadata**. It describes what happened during administrative operations — which tools were invoked, what outcomes occurred, how long operations took — without capturing the substantive content of those operations.

This classification has a specific meaning:

- **Operational metadata is not PII.** It does not identify natural persons. `caller_id` identifies service accounts and operator roles, not individuals. If a deployment uses personal identifiers as caller_id values, that is a deployment configuration error outside this library's control — but the library's design does not require or encourage it.
- **Operational metadata is not forensic evidence.** It does not capture the detailed state changes that the admin-tools-mcp audit trail records (before/after snapshots, parameter values, nonce details). It captures the operational envelope: what action, what outcome, how long, what category.
- **Operational metadata is not application data.** It does not contain business objects, user records, job payloads, cache values, or feature flag configurations. It contains event-level summaries of operations performed on those objects.

---

## 3. Collected Data — Event Envelope

Every event that passes validation and privacy filtering is stored with the following envelope fields:

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `event_type` | String | One of the three known event types | `"action.completed"` |
| `timestamp` | String (ISO 8601) | When the event occurred at the source | `"2026-03-19T14:30:00.000Z"` |
| `caller_id` | String | Service account or operator role identifier | `"service-account-ops"` |
| `action` | String | The operation name | `"retry_job"` |
| `outcome` | String | One of: success, denied, error, preview, rate_limited | `"success"` |
| `duration_ms` | Numeric | Operation latency in milliseconds | `42.5` |
| `metadata` | Hash | Per-event-type approved fields only (see Section 5) | `{"category": "jobs"}` |

Additionally, the telemetry layer adds ingestion metadata:

| Field | Type | Description |
|-------|------|-------------|
| `received_at` | String (ISO 8601) | When the telemetry layer received the event |
| `source_id` | String | Identifier for the event source (configurable) |
| `schema_version` | String | Version of the event schema that was validated against |

---

## 4. Excluded Data — Never Stored

The following data categories are **never stored**, regardless of how they arrive at the telemetry layer. These exclusions are hardcoded safety invariants — they are not configurable and cannot be disabled.

### 4.1 Raw Parameter Values

**What:** The actual parameter values passed to administrative operations. For example, the specific job ID being retried, the cache key being invalidated, the feature flag name being toggled.

**Why excluded:** Parameter values may contain application-specific identifiers, user-facing data, or information that could be used to reconstruct what specific resources were acted upon. The telemetry layer captures that a job retry happened, not which job was retried.

**How enforced:** The event envelope schema does not include a `params` or `parameters` field. If such a field appears in the incoming event, it is stripped by the privacy filter before storage.

### 4.2 Before/After State Snapshots

**What:** The state of affected resources before and after an administrative operation. For example, a job's status before retry, a cache key's value before invalidation, a feature flag's configuration before toggle.

**Why excluded:** State snapshots may contain application data, user information, or business logic details. They are the domain of the admin-tools-mcp audit trail, which is designed for forensic analysis. The telemetry layer captures operational metadata, not forensic evidence.

**How enforced:** Fields named `before_state`, `after_state`, `before`, `after`, `snapshot`, `state_before`, `state_after` (and similar variants) are stripped by the privacy filter. The per-event-type metadata allowlists do not include any snapshot-related fields.

### 4.3 Nonce Values

**What:** Confirmation nonces from the admin-tools-mcp two-phase confirmation protocol.

**Why excluded:** Nonces are cryptographic tokens tied to specific operations. Storing them in telemetry creates a correlation vector between the telemetry store and the admin-tools-mcp audit trail that could be used to join records in unintended ways. The telemetry layer captures whether confirmation was used (`confirmation_used` boolean), not the nonce itself.

**How enforced:** Fields named `nonce`, `confirmation_nonce`, `token`, `confirmation_token` are stripped by the privacy filter.

### 4.4 Stack Traces

**What:** Ruby stack traces from errors that occur during administrative operations.

**Why excluded:** Stack traces contain file paths, class names, method names, and line numbers that reveal internal application structure. They may also contain interpolated data from exception messages. They are debugging data, not operational metadata.

**How enforced:** Fields named `stack_trace`, `stacktrace`, `backtrace`, `trace`, `error_trace` are stripped by the privacy filter.

### 4.5 Adapter-Specific Identifiers

**What:** Identifiers specific to particular backend adapters — Sidekiq JIDs, Redis connection identifiers, GoodJob execution IDs, internal database row IDs.

**Why excluded:** Adapter-specific identifiers create coupling between the telemetry store and specific backend implementations. They can also be used to correlate telemetry records with backend-specific logs in ways that reconstruct operational details the telemetry layer is designed to abstract away.

**How enforced:** Fields named `jid`, `redis_id`, `execution_id`, `internal_id`, `adapter_id`, `backend_id` are stripped by the privacy filter. The per-event-type metadata allowlists do not include adapter-specific fields.

---

## 5. Per-Event-Type Metadata Allowlists

Each event type has an explicit allowlist of metadata keys. Only metadata keys on the allowlist for the event's type are stored. All other metadata keys are stripped before storage. This is defense in depth — even if the upstream source adds a new metadata field, it cannot reach storage until the allowlist is explicitly updated in code.

### 5.1 `action.completed`

Events emitted when an administrative action completes (successfully or otherwise).

| Metadata key | Type | Description |
|-------------|------|-------------|
| `category` | String | Action category (e.g., "jobs", "cache", "flags") |
| `operation` | String | Specific operation within the category (e.g., "retry", "discard", "invalidate") |
| `phase` | String | Execution phase (e.g., "preview", "execute", "confirm") |
| `denial_reason` | String | Why the action was denied, if applicable (e.g., "gate_denied", "rate_limited", "blast_radius_exceeded") |
| `blast_radius_count` | Integer | Number of resources affected by the action |
| `confirmation_used` | Boolean | Whether two-phase confirmation was required and completed |

### 5.2 `gate.evaluated`

Events emitted when the capability gate evaluates an access request.

| Metadata key | Type | Description |
|-------------|------|-------------|
| `gate_result` | String | Gate evaluation outcome (e.g., "approved", "denied", "unavailable") |
| `capability_checked` | String | The capability that was evaluated (e.g., "admin.jobs.retry") |

### 5.3 `rate_limit.checked`

Events emitted when a rate limit is checked for an action.

| Metadata key | Type | Description |
|-------------|------|-------------|
| `rate_result` | String | Rate limit check outcome (e.g., "allowed", "rate_limited") |
| `current_count` | Integer | Current invocation count within the rate limit window |
| `limit` | Integer | Maximum allowed invocations within the window |
| `window_seconds` | Integer | Rate limit window duration in seconds |

---

## 6. Retention Policy

### 6.1 Configurable Retention Window

Events are retained for a configurable duration. The default retention window is **90 days**. Events older than the retention window are eligible for automatic purge.

The retention window is configured at startup and cannot be changed at runtime (startup-only configuration invariant).

### 6.2 Automatic Purge

Purge of expired events is triggered opportunistically during store operations (write, query, export) and can also be triggered explicitly via the store's `purge(before:)` method.

Purge is not real-time — there may be a brief period where expired events exist in storage before the next purge cycle. This is acceptable. The guarantee is: expired events are not included in query results or export output, even if they have not yet been physically removed from storage.

### 6.3 Size-Based Retention

In addition to time-based retention, `JsonLinesStore` supports a configurable maximum storage size. When the storage size exceeds the configured maximum, the oldest events are purged first until the size is within bounds.

Size-based retention is a safety net for high-volume deployments. It ensures that even if the time-based retention window is long, storage does not grow beyond operational limits.

### 6.4 Retention Defaults

| Parameter | Default | Configurable | Constraints |
|-----------|---------|-------------|-------------|
| `retention_days` | 90 | Yes, at startup | Minimum 1 day, no maximum |
| `max_storage_bytes` | 1 GB | Yes, at startup | Minimum 1 MB, no maximum |
| `max_memory_events` | 100,000 | Yes, at startup | Minimum 100, no maximum |

---

## 7. Consent Model

### 7.1 Opt-In at Source

Telemetry collection is opt-in. The consuming application must explicitly attach the telemetry subscriber to the event source (HookEmitter). If the subscriber is not attached, no events are collected. There is no automatic, implicit, or background collection.

### 7.2 No Retroactive Collection

The telemetry layer only processes events that arrive through the `receive(event)` interface while the subscriber is active. It does not scan logs, replay event streams, or backfill historical data. Collection begins when the subscriber is attached and ends when it is detached.

### 7.3 No External Transmission

The telemetry library stores data locally and exports to local files. It does not transmit data to external services, cloud endpoints, or third-party analytics platforms. Export is a local file operation that the operator controls. If an operator chooses to send export files to an external service, that is the operator's decision and outside this library's scope.

---

## 8. Aggregation Privacy

### 8.1 No PII in Aggregations

Aggregation output (session summaries, tool utilization, outcome distributions, latency statistics) must not enable re-identification of individual callers or individual operations when the population is sufficiently large.

### 8.2 Minimum Population Thresholds

Aggregations that cover fewer than a configurable minimum number of events (default: 5) are suppressed from export. This prevents aggregations over single-caller or single-event populations from effectively identifying individual operations.

### 8.3 Aggregation Limitations

This library acknowledges that aggregation privacy is a best-effort property, not a cryptographic guarantee. In deployments with very few callers or very few action types, even population-thresholded aggregations may leak information about individual usage patterns. The library documents this limitation and recommends that operators in small deployments review aggregation output before sharing it externally.

---

## 9. Privacy Model Invariants

These are the testable invariants that Epic 8 (adversarial testing) must verify:

1. **No forbidden field survives to storage.** Any event containing raw parameter values, before/after snapshots, nonce values, stack traces, or adapter-specific identifiers has those fields stripped before storage.
2. **Per-type allowlists are enforced.** Metadata keys not on the allowlist for the event's type do not reach storage.
3. **Allowlists are not configurable.** The allowlists are defined in code. There is no configuration mechanism to add, remove, or modify allowlist entries at runtime or startup.
4. **Expired events are not exported.** Events past the retention window are excluded from query results and export output.
5. **Storage size is bounded.** The store does not grow beyond the configured maximum size.
6. **Collection is opt-in.** No events are collected unless the subscriber is explicitly attached.
7. **Small-population aggregations are suppressed.** Aggregations below the minimum population threshold are not included in export output.
8. **Privacy filtering is not bypassable.** There is no code path that stores an event without passing through the privacy filter.
