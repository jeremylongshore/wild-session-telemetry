# wild-session-telemetry — Architecture Decisions

**Document type:** Architecture decision record
**Filed as:** `007-AT-ADEC-architecture-decisions.md`
**Repo:** `wild-session-telemetry`
**Status:** Active — Phase 0 planning
**Last updated:** 2026-03-19
**Blueprint reference:** `001-PP-PLAN-repo-blueprint.md`

---

## 1. Purpose

This document records the key architecture decisions for `wild-session-telemetry`, with rationale for each. These decisions shape the implementation and constrain future changes. They are not arbitrary — each decision solves a specific problem or prevents a specific failure mode.

Architecture decisions are harder to change than code. Document them now so that future sessions understand why the system is shaped the way it is, and what trade-offs were accepted.

---

## 2. The Decisions

### Decision 1: Pure Library, Not a Server

**Decision:** `wild-session-telemetry` is a pure Ruby library gem. Consumers require it as a gem dependency and call Ruby methods directly. It is not an MCP server, not a standalone process, and not a network service.

**Context:** The wild ecosystem already has MCP servers (`wild-rails-safe-introspection-mcp`, `wild-admin-tools-mcp`). A telemetry service could be built as another MCP server that consumers call over the wire. Alternatively, it could be a background process that reads from a queue.

**Rationale:**
- Telemetry ingestion must be fire-and-forget with minimal latency. Network calls add latency and failure modes. In-process method calls are fast and reliable.
- The primary upstream source (admin-tools-mcp) already defines a subscriber interface (`receive(event)`) for in-process hook consumption. A library gem implements this interface directly.
- The primary downstream consumer (gap-miner) needs to read export files, not call a network API. The export is a file operation.
- A server adds deployment complexity (process management, health checks, network configuration) that is unnecessary for a library that runs in the same process as its source.
- A library has zero operational overhead — no ports to open, no processes to monitor, no network to secure.

**Trade-offs accepted:**
- The library runs in the same process as the event source. If the process crashes, in-memory telemetry data is lost (mitigated by JsonLinesStore for durable persistence).
- The library shares the event source's Ruby runtime. CPU-intensive aggregation competes with the source's workload (mitigated by computing aggregations on demand, not continuously).
- Multi-process deployments require shared storage (JsonLinesStore on a shared filesystem) or per-process stores with post-hoc merge (not in v1 scope).

**Alternatives rejected:**
- MCP server: too much operational complexity for the value delivered.
- Background process with queue: adds message broker dependency, deployment complexity, and latency.
- Sidecar process: adds IPC complexity without clear benefit over in-process.

---

### Decision 2: MemoryStore + JsonLinesStore (Proven Admin-Tools-MCP Pattern)

**Decision:** The storage layer provides two implementations: `MemoryStore` for in-process ephemeral storage and `JsonLinesStore` for durable on-disk persistence. Both implement a common store interface.

**Context:** Admin-tools-mcp established this pattern for its audit trail storage. It works well for append-heavy workloads with time-based retention. The question is whether to reuse this proven pattern or adopt something more sophisticated (SQLite, embedded database, external datastore).

**Rationale:**
- JSON Lines is the simplest durable format that supports append-only writes, line-by-line reads, and straightforward retention (delete old files or truncate).
- MemoryStore is essential for testing — tests should not require file system access.
- MemoryStore is also useful for lightweight embedded deployments where durability is not required.
- The common store interface allows future storage backends without changing consumer code.
- SQLite adds a native extension dependency. JSON Lines is pure Ruby.
- External datastores (Redis, PostgreSQL) add network dependencies and operational complexity that contradict Decision 1 (pure library).

**Trade-offs accepted:**
- JSON Lines queries are sequential scans. For v1 volumes (thousands to tens of thousands of events), this is acceptable. For higher volumes, indexed storage would be needed (v2 extension point).
- File-based storage requires filesystem access. In containerized or serverless environments, persistent filesystem access may not be available (operators can use MemoryStore or mount persistent volumes).
- No built-in indexing. Complex queries (multi-field filters, range queries on non-timestamp fields) are O(n) over stored events.

**Alternatives rejected:**
- SQLite: adds native extension dependency, complicates installation.
- Redis: adds external dependency, contradicts pure library decision.
- Custom binary format: adds complexity without clear v1 benefit.

---

### Decision 3: Flat Namespace `WildSessionTelemetry`

**Decision:** All library code lives under a single flat namespace: `WildSessionTelemetry`. Classes are named directly (e.g., `WildSessionTelemetry::EventReceiver`, `WildSessionTelemetry::MemoryStore`, `WildSessionTelemetry::PrivacyFilter`). No nested module hierarchy.

**Context:** Admin-tools-mcp uses the same flat namespace pattern (`WildAdminToolsMcp::`). The wild ecosystem has established this as a convention. The question is whether to follow the convention or adopt a nested hierarchy (e.g., `WildSessionTelemetry::Store::Memory`, `WildSessionTelemetry::Filter::Privacy`).

**Rationale:**
- Consistency with the ecosystem convention. Developers working across wild repos should find the same namespace patterns.
- Flat namespaces are simpler to navigate. `WildSessionTelemetry::MemoryStore` is more discoverable than `WildSessionTelemetry::Store::Memory`.
- The library is small enough (estimated 10-15 classes in v1) that a flat namespace does not create naming collisions.
- Nested namespaces imply a deeper abstraction hierarchy than this library warrants. It is a focused library, not a framework.

**Trade-offs accepted:**
- If the library grows significantly beyond v1 scope, the flat namespace may become crowded. This is a v2 concern — rename with a major version bump if needed.
- Some class names may be longer to avoid ambiguity (e.g., `JsonLinesStore` instead of `Store` in a `JsonLines` namespace).

---

### Decision 4: Schema Validation at Ingestion, Not Export

**Decision:** Events are validated against the schema when they arrive at the `receive(event)` boundary. Invalid events are rejected before they reach storage. Validation does not occur at export time — the export pipeline trusts that stored data is already valid.

**Context:** There are two points where validation could occur: at ingestion (before storage) or at export (before consumers see the data). Validating at both points is possible but redundant if the ingestion validator is trustworthy.

**Rationale:**
- Fail early, store clean data. If invalid data reaches storage, it contaminates every query, aggregation, and export that touches it. Cleaning up corrupted storage is much harder than preventing corruption.
- Storage is the authoritative data layer. If stored data cannot be trusted, no operation on it is trustworthy. Validation at ingestion establishes trust at the source.
- Export-time validation adds latency to exports and complicates the export path. If the store is clean, the export pipeline is a straightforward transformation.
- Defense in depth is achieved through the privacy filter (which operates after validation but before storage), not through redundant validation at export.

**Trade-offs accepted:**
- If a bug in the validator allows invalid data to reach storage, the stored data is corrupted and exports will include invalid records. Mitigation: comprehensive validator tests including adversarial cases.
- If the schema definition changes (new required field), existing stored events are not retroactively validated. They were valid at the time of ingestion. Exports include them as-is with their original schema version.

---

### Decision 5: Ingestion and Export as Independent Subsystems

**Decision:** The ingestion pipeline (receive -> validate -> filter -> store) and the export pipeline (query -> aggregate -> format -> output) are independent subsystems that share a store but have no other coupling. They can evolve, be tested, and be configured independently.

**Context:** An alternative design would tightly couple ingestion and export — for example, computing export records as events are ingested (streaming aggregation) or maintaining running counters that are updated on each ingestion.

**Rationale:**
- Independent subsystems are simpler to understand, test, and debug. A bug in export cannot affect ingestion. A change to aggregation logic does not require retesting the ingestion path.
- Ingestion must be fast and fire-and-forget. Coupling it to export or aggregation computation would add latency to the ingestion path, potentially blocking the upstream event source.
- Export operates on demand, not continuously. Computing aggregations on every event ingestion wastes CPU when no one is reading the aggregations.
- The store interface is the clean boundary. Both subsystems depend on the store. Neither depends on the other.
- Independent evolution: the ingestion pipeline is constrained by the upstream event schema; the export pipeline is constrained by the downstream consumer contract. These constraints change independently.

**Trade-offs accepted:**
- On-demand aggregation is slower than pre-computed aggregation for large datasets. For v1 volumes, on-demand computation is fast enough. Pre-computation is a v2 optimization if needed.
- The store must support efficient queries for the export pipeline's needs. If the store is too slow for export queries, the export pipeline cannot compensate.

---

### Decision 6: Startup-Only Configuration

**Decision:** All configuration is set at startup (object initialization) and frozen. There is no mechanism to change configuration at runtime. This applies to: store backend selection, retention windows, size limits, source ID, and all other parameters.

**Context:** Many libraries support runtime reconfiguration — hot-reloading config files, setter methods, admin interfaces. This is convenient but creates a class of bugs and security issues where configuration changes during operation invalidate assumptions made by running code.

**Rationale:**
- Immutable configuration eliminates runtime tampering (Threat 7 in the threat model). If configuration cannot change, it cannot be changed maliciously or accidentally.
- Immutable configuration simplifies reasoning about system behavior. The system behaves the same way from startup to shutdown. There are no "before the config change" and "after the config change" states to consider.
- The telemetry library runs as part of a larger application. Restarting the application to change telemetry configuration is a standard operational practice, not an undue burden.
- Ruby's `freeze` mechanism provides language-level enforcement — frozen objects raise FrozenError on modification attempts.

**Trade-offs accepted:**
- Changing any configuration parameter requires a process restart. In long-running processes, this means a brief interruption.
- Emergency configuration changes (e.g., reducing retention to free disk space) require a restart, which adds latency to incident response. Mitigation: operational procedures for emergency restarts should be documented.

---

### Decision 7: `Data.define` for Immutable Event Envelopes (Ruby 3.2+ Pattern)

**Decision:** Validated event records are represented as instances of `Data.define` classes — Ruby 3.2's built-in mechanism for immutable value objects. Events are not stored as mutable Hashes.

**Context:** Ruby offers several ways to represent structured data: plain Hashes, Struct, OpenStruct, custom classes, and Data (Ruby 3.2+). Admin-tools-mcp uses Data.define for its immutable records. The question is whether to follow this pattern or use simpler Hashes.

**Rationale:**
- `Data.define` produces frozen (immutable) instances by default. Once an event is validated and stored, it cannot be accidentally modified. This supports the broader immutability theme of the safety model.
- `Data.define` provides named fields with type-safe access (`event.event_type` instead of `event[:event_type]` or `event["event_type"]`). This catches field name typos at development time rather than producing nil at runtime.
- `Data.define` includes equality comparison by value, which simplifies testing (two events with the same fields are `==`).
- `Data.define` is a stdlib feature — no gem dependency required.
- Consistency with admin-tools-mcp's convention.

**Trade-offs accepted:**
- Requires Ruby 3.2+. Deployments on older Ruby versions cannot use this library. This is acceptable — Ruby 3.2 was released in December 2022 and is the minimum supported version for this ecosystem.
- `Data.define` instances must be explicitly converted to Hashes for JSON serialization. The store layer handles this conversion.
- `Data.define` does not support optional fields natively — all fields are required at initialization. Metadata fields that may be absent must default to nil or an empty value in the factory method.

---

## 3. Decision Summary Table

| # | Decision | Key rationale | Primary alternative rejected |
|---|----------|--------------|---------------------------|
| 1 | Pure library, not a server | Minimal operational overhead; fire-and-forget latency | MCP server |
| 2 | MemoryStore + JsonLinesStore | Proven pattern; pure Ruby; no external dependencies | SQLite |
| 3 | Flat namespace | Ecosystem consistency; simplicity | Nested module hierarchy |
| 4 | Validate at ingestion, not export | Fail early; store clean data | Export-time validation |
| 5 | Independent ingestion and export | Simplicity; independent evolution; fast ingestion | Streaming aggregation |
| 6 | Startup-only configuration | Eliminates runtime tampering; simplifies reasoning | Runtime reconfiguration |
| 7 | Data.define for event envelopes | Immutability by default; type-safe access; ecosystem consistency | Plain Hashes |

---

## 4. Decision-to-Safety Mapping

Several architecture decisions exist specifically to support safety rules:

| Decision | Supports safety rules |
|----------|----------------------|
| Decision 1 (pure library) | Rule 5 (fire-and-forget — in-process calls minimize failure modes) |
| Decision 4 (validate at ingestion) | Rules 2, 3 (schema validation and field stripping before storage) |
| Decision 5 (independent subsystems) | Rule 5 (ingestion failures isolated from export) |
| Decision 6 (startup-only config) | Rule 8 (immutable configuration) |
| Decision 7 (Data.define) | Rules 1, 3 (immutable events cannot be modified after validation) |
