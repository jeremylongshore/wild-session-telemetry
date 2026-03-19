# wild-session-telemetry — v2 Expansion Roadmap

**Document type:** Project planning
**Filed as:** `011-PP-PLAN-v2-expansion-roadmap.md`
**Repo:** `wild-session-telemetry`
**Status:** Active — future planning
**Last updated:** 2026-03-19
**Blueprint reference:** `001-PP-PLAN-repo-blueprint.md`

---

## 1. Purpose

This document identifies extension points in the v1 architecture and candidate features for v2. Nothing here is committed — these are informed possibilities based on the v1 implementation experience.

---

## 2. Extension Points in v1

The v1 architecture was designed with clear boundaries that enable future extension without rewriting core components.

### 2.1 Store Layer

The `Store::Base` interface defines 6 methods (`append`, `recent`, `find`, `count`, `query`, `clear!`). Any class implementing this interface can serve as a storage backend.

**v2 candidates:**
- `SqliteStore` — SQLite-backed storage for better query performance on large datasets
- `RedisStore` — Redis-backed storage for multi-process deployments
- `NullStore` — no-op store for environments where telemetry is disabled

### 2.2 Export Pipeline

The `Exporter` accepts pluggable `record_builder`, `aggregator`, and `pattern_detector` instances. New record types can be added by extending `RecordBuilder`.

**v2 candidates:**
- OpenTelemetry span export adapter (maps native events to OTel spans)
- CSV export format for spreadsheet analysis
- Streaming export for large datasets (lazy enumeration instead of array)

### 2.3 Aggregation

The `Engine` and `PatternDetector` are injected into the `Exporter`. New aggregation types can be added without modifying existing ones.

**v2 candidates:**
- Anomaly detection (statistical outlier identification)
- Trend analysis (week-over-week comparison)
- Correlation analysis (which actions tend to follow which)

### 2.4 Event Types

The validator's `VALID_EVENT_TYPES` and filter's `METADATA_ALLOWLISTS` are the only places that define event types. Adding a new event type requires updating both constants.

**v2 candidates:**
- `session.started` / `session.ended` — session lifecycle events
- `error.occurred` — standalone error events (not tied to an action)

### 2.5 Privacy Filter

The filter's `FORBIDDEN_FIELD_NAMES` and `ALLOWED_VALUE_TYPES` can be extended. Value-level content inspection could be added as a new filter stage.

**v2 candidates:**
- Regex-based value scanning (detect PII patterns in allowed fields)
- Configurable forbidden field lists (per-deployment additions to the hardcoded list)

---

## 3. Cross-Repo Integration Points

### 3.1 wild-admin-tools-mcp

The primary event source. v2 could add:
- Event ID field for deduplication (Threat 5 mitigation)
- Richer metadata for new action categories

### 3.2 wild-gap-miner

The primary export consumer. v2 could add:
- Direct API integration (gap-miner reads exports programmatically)
- Schema negotiation (gap-miner requests specific export schema version)

### 3.3 wild-transcript-pipeline

Secondary consumer. v2 could add:
- Correlation IDs linking telemetry events to transcript segments

---

## 4. Infrastructure Candidates

| Candidate | Priority | Rationale |
|-----------|----------|-----------|
| Event deduplication | High | Mitigates Threat 5 (replay inflation) |
| OpenTelemetry export adapter | Medium | Ecosystem interoperability |
| SQLite store backend | Medium | Better query performance at scale |
| Streaming export | Low | Only needed for very large datasets |
| Differential privacy | Low | Formal privacy guarantees beyond thresholds |
| Value-level PII scanning | Low | Defense in depth for metadata values |

---

## 5. Non-Candidates

These were considered and explicitly rejected for v2:

- **MCP server layer** — upstream repos own their MCP interfaces
- **Real-time streaming** — telemetry is batch-oriented by design
- **Dashboard/visualization** — outside this repo's scope
- **Multi-tenant isolation** — single-deployment library
