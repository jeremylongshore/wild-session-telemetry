# wild-session-telemetry — Data Contracts

**Document type:** Architecture standard
**Filed as:** `004-AT-STND-data-contracts.md`
**Repo:** `wild-session-telemetry`
**Status:** Active — Phase 0 planning
**Last updated:** 2026-03-19
**Blueprint reference:** `001-PP-PLAN-repo-blueprint.md`

---

## 1. Purpose

This document defines the data contracts for `wild-session-telemetry`: the input contract (what the library accepts), the internal storage format (how it stores data), and the output contract (what downstream consumers can depend on). It also defines the versioning strategy for schemas.

Data contracts are the interfaces between systems. Getting them right — and keeping them stable — is the difference between a composable library and a fragile dependency. This document is the source of truth for what crosses each boundary.

---

## 2. Input Contract — Event Envelope from Doc 018

The input contract is defined by `wild-admin-tools-mcp` doc 018. The telemetry library validates against this contract but does not own it. Changes to the input contract originate in admin-tools-mcp.

### 2.1 Event Envelope Schema

```json
{
  "event_type": "action.completed",
  "timestamp": "2026-03-19T14:30:00.000Z",
  "caller_id": "service-account-ops",
  "action": "retry_job",
  "outcome": "success",
  "duration_ms": 42.5,
  "metadata": {}
}
```

### 2.2 Required Fields

| Field | Type | Required | Constraints |
|-------|------|----------|-------------|
| `event_type` | String | Yes | Must be one of: `action.completed`, `gate.evaluated`, `rate_limit.checked` |
| `timestamp` | String | Yes | Must be valid ISO 8601 datetime |
| `caller_id` | String | Yes | Non-empty string |
| `action` | String | Yes | Non-empty string |
| `outcome` | String | Yes | Must be one of: `success`, `denied`, `error`, `preview`, `rate_limited` |
| `duration_ms` | Numeric | Yes | Non-negative number |
| `metadata` | Hash | Yes | May be empty; contents validated per event type (see Section 2.3) |

### 2.3 Per-Event-Type Metadata

Metadata contents vary by event type. The telemetry library validates metadata keys against per-type allowlists defined in `003-TQ-STND-privacy-model.md`.

**`action.completed` metadata:**

| Key | Type | Description |
|-----|------|-------------|
| `category` | String | Action category |
| `operation` | String | Specific operation |
| `phase` | String | Execution phase |
| `denial_reason` | String | Denial reason if applicable |
| `blast_radius_count` | Integer | Resources affected |
| `confirmation_used` | Boolean | Whether confirmation was required |

**`gate.evaluated` metadata:**

| Key | Type | Description |
|-----|------|-------------|
| `gate_result` | String | Gate evaluation outcome |
| `capability_checked` | String | Capability evaluated |

**`rate_limit.checked` metadata:**

| Key | Type | Description |
|-----|------|-------------|
| `rate_result` | String | Rate check outcome |
| `current_count` | Integer | Current count in window |
| `limit` | Integer | Maximum allowed |
| `window_seconds` | Integer | Window duration |

### 2.4 Validation Behavior

- Events missing required fields are silently rejected (not stored, no error propagated)
- Events with unknown `event_type` values are silently rejected
- Events with invalid `outcome` values are silently rejected
- Events with non-numeric `duration_ms` are silently rejected
- Events with invalid `timestamp` format are silently rejected
- Metadata keys not on the per-type allowlist are stripped (event is still stored with remaining valid metadata)
- Events with empty metadata are valid and stored

### 2.5 Subscriber Interface

The telemetry library implements the subscriber interface defined by admin-tools-mcp's HookEmitter:

```ruby
# The subscriber must respond to receive(event)
# event is a Hash with the envelope fields above
class WildSessionTelemetry::EventReceiver
  def receive(event)
    # validate, filter, store
    # MUST NOT raise — fire-and-forget
  end
end
```

---

## 3. Internal Storage Format

The internal storage format is an implementation detail. Downstream consumers must not depend on it. It may change without notice between versions. This section documents it for maintainer reference only.

### 3.1 Stored Event Record

Each stored event includes the validated, privacy-filtered event envelope plus ingestion metadata:

```json
{
  "event_type": "action.completed",
  "timestamp": "2026-03-19T14:30:00.000Z",
  "caller_id": "service-account-ops",
  "action": "retry_job",
  "outcome": "success",
  "duration_ms": 42.5,
  "metadata": {
    "category": "jobs",
    "operation": "retry",
    "phase": "execute",
    "blast_radius_count": 1,
    "confirmation_used": true
  },
  "received_at": "2026-03-19T14:30:00.123Z",
  "source_id": "admin-tools-mcp-production",
  "schema_version": "1.0.0"
}
```

### 3.2 Ingestion Metadata

| Field | Type | Description | Source |
|-------|------|-------------|--------|
| `received_at` | String (ISO 8601) | When the telemetry layer received and stored the event | Generated by EventReceiver |
| `source_id` | String | Identifier for the event source; configurable at startup | From Configuration |
| `schema_version` | String (semver) | Version of the event schema validated against | From SchemaValidator |

### 3.3 MemoryStore Format

In MemoryStore, events are held as an in-process array of frozen Hash objects. Query is linear scan with filtering. Purge removes elements from the array. This is intentionally simple.

### 3.4 JsonLinesStore Format

In JsonLinesStore, each event is a single JSON object on a single line in a `.jsonl` file. Files are named with timestamps for rotation support:

```
telemetry-2026-03-19T000000.jsonl
telemetry-2026-03-20T000000.jsonl
```

Each line is a complete, self-contained JSON object (the stored event record from Section 3.1). No framing, no delimiters beyond newlines. This is the standard JSON Lines format.

---

## 4. Output Contract — Export Format

The output contract is the stable interface that downstream consumers depend on. It is versioned, documented, and subject to semver compatibility guarantees. Consumers should depend on the export contract, never on the internal storage format.

### 4.1 Export File Format

Exports are JSON Lines files (`.jsonl`). Each line is a self-contained JSON object. The first line is a metadata header.

### 4.2 Export Header

The first line of every export file is a metadata header:

```json
{
  "export_type": "session_telemetry",
  "schema_version": "1.0.0",
  "exported_at": "2026-03-19T15:00:00.000Z",
  "source_id": "admin-tools-mcp-production",
  "time_range": {
    "start": "2026-03-12T00:00:00.000Z",
    "end": "2026-03-19T15:00:00.000Z"
  },
  "record_counts": {
    "events": 1523,
    "session_summaries": 47,
    "tool_utilization": 12,
    "outcome_distributions": 12,
    "pattern_records": 8
  }
}
```

### 4.3 Export Record Types

Each subsequent line is a typed record. The `record_type` field identifies the type.

**Event record:**

```json
{
  "record_type": "event",
  "event_type": "action.completed",
  "timestamp": "2026-03-19T14:30:00.000Z",
  "caller_id": "service-account-ops",
  "action": "retry_job",
  "outcome": "success",
  "duration_ms": 42.5,
  "metadata": {
    "category": "jobs",
    "operation": "retry",
    "confirmation_used": true
  }
}
```

**Session summary record:**

```json
{
  "record_type": "session_summary",
  "caller_id": "service-account-ops",
  "window_start": "2026-03-19T14:00:00.000Z",
  "window_end": "2026-03-19T15:00:00.000Z",
  "event_count": 23,
  "distinct_actions": ["retry_job", "inspect_job", "discard_job"],
  "outcome_breakdown": {
    "success": 18,
    "denied": 2,
    "error": 1,
    "preview": 2,
    "rate_limited": 0
  },
  "total_duration_ms": 1247.3
}
```

**Tool utilization record:**

```json
{
  "record_type": "tool_utilization",
  "action": "retry_job",
  "invocation_count": 156,
  "unique_callers": 4,
  "success_rate": 0.923,
  "avg_duration_ms": 38.7,
  "window_start": "2026-03-12T00:00:00.000Z",
  "window_end": "2026-03-19T15:00:00.000Z"
}
```

**Outcome distribution record:**

```json
{
  "record_type": "outcome_distribution",
  "action": "retry_job",
  "window_start": "2026-03-12T00:00:00.000Z",
  "window_end": "2026-03-19T15:00:00.000Z",
  "total_count": 156,
  "outcomes": {
    "success": {"count": 144, "percentage": 0.923},
    "denied": {"count": 5, "percentage": 0.032},
    "error": {"count": 3, "percentage": 0.019},
    "preview": {"count": 2, "percentage": 0.013},
    "rate_limited": {"count": 2, "percentage": 0.013}
  }
}
```

**Latency statistics record:**

```json
{
  "record_type": "latency_stats",
  "action": "retry_job",
  "window_start": "2026-03-12T00:00:00.000Z",
  "window_end": "2026-03-19T15:00:00.000Z",
  "sample_count": 156,
  "p50_ms": 35.2,
  "p95_ms": 78.4,
  "p99_ms": 142.1,
  "min_ms": 8.3,
  "max_ms": 312.7,
  "avg_ms": 38.7
}
```

**Pattern record:**

```json
{
  "record_type": "pattern",
  "pattern_type": "sequential",
  "sequence": ["inspect_job", "retry_job", "inspect_job"],
  "occurrence_count": 34,
  "unique_callers": 3,
  "avg_total_duration_ms": 127.4,
  "window_start": "2026-03-12T00:00:00.000Z",
  "window_end": "2026-03-19T15:00:00.000Z"
}
```

### 4.4 Export Filtering

Exports can be filtered by:

| Filter | Type | Description |
|--------|------|-------------|
| `time_range` | Start/end ISO 8601 | Only include events within the time range |
| `event_types` | Array of strings | Only include specified event types |
| `caller_ids` | Array of strings | Only include events from specified callers |
| `actions` | Array of strings | Only include events for specified actions |

Filters apply to event records. Aggregation and pattern records are recomputed from the filtered event set.

---

## 5. Schema Versioning

### 5.1 Versioning Strategy

All schemas (input validation, internal storage, export output) are versioned using semantic versioning (semver):

- **Major version bump:** Breaking changes — fields removed, field types changed, required fields added, record types removed
- **Minor version bump:** Backward-compatible additions — new optional fields, new record types, new metadata keys added to allowlists
- **Patch version bump:** Clarifications, documentation fixes, no schema changes

### 5.2 Compatibility Guarantees

**Input contract:** The telemetry library validates against a specific input schema version. It should accept events from the same major version (forward-compatible within a major). Unknown fields in the envelope (outside metadata) are ignored, not rejected — this allows the input schema to add fields without breaking the telemetry validator.

**Export contract:** The export schema is the primary stability guarantee. Consumers depend on it. Within a major version:
- No fields are removed from existing record types
- No field types change
- New optional fields may be added
- New record types may be added
- Existing record type semantics do not change

**Internal storage format:** No compatibility guarantees. May change between any version. Consumers must not depend on it.

### 5.3 Version Negotiation

There is no runtime version negotiation in v1. The library validates against and exports in a single schema version. If the input schema version does not match, events are rejected. If a consumer needs a different export schema version, it must use a compatible library version.

Future versions may support multi-version export (generating output in older schema versions for backward compatibility). This is not a v1 feature.

---

## 6. Contract Boundaries

### 6.1 What Consumers Can Depend On

- The export file format (JSON Lines with header)
- The export record types and their fields (within a major version)
- The export schema version (semver, in the header)
- The `receive(event)` subscriber interface
- The fire-and-forget behavior of `receive(event)`

### 6.2 What Consumers Must Not Depend On

- Internal storage file paths or naming
- Internal storage format (JSON structure within `.jsonl` files)
- MemoryStore's in-process data structure
- JsonLinesStore's file rotation strategy
- The order of records within an export file (beyond the header being first)
- Aggregation computation algorithms (the outputs are stable; the computation may change)
- Pattern detection algorithms (the output format is stable; which patterns are detected may evolve)

### 6.3 Cross-Repo Contract Ownership

| Contract | Owner | Consumer | Change process |
|----------|-------|----------|----------------|
| Event envelope schema | `wild-admin-tools-mcp` | `wild-session-telemetry` | Admin-tools-mcp changes schema; telemetry updates validator |
| Subscriber interface | `wild-admin-tools-mcp` | `wild-session-telemetry` | `receive(event)` contract defined by HookEmitter |
| Export schema | `wild-session-telemetry` | `wild-gap-miner` | Telemetry owns schema; gap-miner depends on it |
| Export file format | `wild-session-telemetry` | Any downstream consumer | Telemetry owns format; consumers depend on JSON Lines + header |
