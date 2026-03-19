# wild-session-telemetry — Threat Model

**Document type:** Architecture decision
**Filed as:** `006-AT-ADEC-threat-model.md`
**Repo:** `wild-session-telemetry`
**Status:** Active — Phase 0 planning
**Last updated:** 2026-03-19
**Blueprint reference:** `001-PP-PLAN-repo-blueprint.md`

---

## 1. Purpose

This document identifies 8 threats specific to `wild-session-telemetry` and describes mitigations for each. The threats are grounded in the repo's actual architecture: a pure library gem that ingests structured events, filters them for privacy, stores them durably, and exports aggregated data for downstream consumers.

These are not hypothetical risks. Each threat describes a concrete scenario that could occur in a real deployment and would cause real harm if unmitigated.

---

## 2. Threat Scope

The threat model covers the telemetry library's data lifecycle:

1. **Ingestion** — events arrive from upstream sources
2. **Validation** — events are checked against the schema
3. **Privacy filtering** — forbidden fields are stripped
4. **Storage** — clean events are persisted
5. **Aggregation** — summaries are computed from stored events
6. **Export** — aggregated and raw data is exported for consumers

Each threat targets one or more stages in this lifecycle.

---

## 3. The Threats

### Threat 1: PII Leakage Through Metadata Fields

**Stage:** Ingestion, Privacy filtering

**Scenario:** The upstream event source (admin-tools-mcp) includes a new metadata field that contains personally identifiable information or sensitive application data. For example, a future version adds a `user_email` field to `action.completed` metadata, or a buggy emitter includes raw `params` in the metadata hash. If the telemetry layer stores this data, it becomes a PII repository without the access controls, retention policies, or legal framework appropriate for PII.

**Impact:** Compliance violations. Data breach liability. Erosion of trust in the telemetry layer's privacy guarantees. If the stored PII is included in exports consumed by gap-miner or other downstream systems, the leak propagates.

**Mitigations:**
- Per-event-type metadata allowlisting (Safety Rule 6) — only explicitly approved keys pass through. New fields from the upstream source are blocked by default.
- Global forbidden field stripping (Safety Rule 3) — known forbidden patterns (`params`, `before_state`, `nonce`, etc.) are stripped regardless of event type.
- Allowlists are hardcoded in code, not configurable — adding a new allowed field requires a code change and review.
- Adversarial tests (Epic 8) specifically attempt to pass PII through metadata fields.

**Residual risk:** If the upstream source puts PII in a field that happens to match an allowlisted key name (e.g., puts an email address in the `category` field), the telemetry layer will store it. Allowlisting is by key name, not value content. Value inspection is not implemented in v1 because it requires understanding the semantics of every possible value, which is impractical. This limitation is documented.

---

### Threat 2: Unbounded Storage Growth from High-Volume Event Streams

**Stage:** Storage

**Scenario:** A high-throughput deployment emits thousands of events per minute. The JsonLinesStore writes events faster than retention purge removes them. Over days or weeks, disk usage grows until the host runs out of space, causing cascading failures in the application that hosts the telemetry library.

**Impact:** Disk exhaustion on the host system. Potential cascade to the application layer if the telemetry library shares a filesystem with the application. Operational incidents caused by a system that was supposed to be an observer.

**Mitigations:**
- Configurable retention window (default 90 days) with automatic time-based purge (Safety Rule 4)
- Configurable maximum storage size (default 1 GB) with automatic oldest-first purge when exceeded (Safety Rule 4)
- Configurable maximum memory events for MemoryStore (default 100,000)
- Opportunistic purge during write operations — every write checks whether purge is needed
- Storage size monitoring via the store's `size` method — operators can monitor and alert

**Residual risk:** Between purge cycles, storage may briefly exceed the configured maximum by the size of events written since the last purge. The overshoot is bounded by the write rate times the purge interval, which is small for typical deployments.

---

### Threat 3: Schema Injection via Malformed Event Data

**Stage:** Ingestion, Validation

**Scenario:** A malicious or buggy upstream source sends events with carefully crafted field values designed to exploit downstream processing. For example: an `event_type` value that contains special characters, a `metadata` field that is a string instead of a hash, a `duration_ms` value that is a string containing JavaScript, or a `timestamp` value that overflows a date parser.

**Impact:** If malformed data reaches storage, it could corrupt the store, cause errors during aggregation or export, or exploit vulnerabilities in downstream consumers that parse the export output.

**Mitigations:**
- Schema validation at ingestion (Safety Rule 2) — field types are checked (String for strings, Numeric for duration_ms, Hash for metadata)
- Known-value validation — `event_type` must match one of three known values, `outcome` must match one of five known values
- Silent rejection — malformed events are dropped before reaching storage, preventing corruption
- JSON serialization for storage — data is serialized through Ruby's JSON library, which handles type safety

**Residual risk:** The schema validator checks types and known values but does not validate the semantic content of string fields. A string field could contain arbitrary content (very long strings, Unicode edge cases, control characters). V1 relies on JSON serialization to handle encoding safely. Deep content validation is not in scope.

---

### Threat 4: Export Re-Identification from Small-Population Aggregations

**Stage:** Aggregation, Export

**Scenario:** A deployment has few callers or few action types. Aggregation output reveals individual usage patterns. For example, if only one service account uses `retry_job`, the tool utilization record for `retry_job` effectively identifies that account's usage volume and patterns. A downstream consumer with access to the export can reconstruct individual behavior.

**Impact:** Privacy violation — operational metadata effectively becomes per-caller surveillance data. Trust erosion if operators discover that telemetry exports reveal their individual activity patterns.

**Mitigations:**
- Minimum population threshold for aggregation output (Safety Rule 7) — aggregations below the configured minimum event count (default: 5) are suppressed
- Aggregations report population-level metrics, not per-event details
- Documentation of the limitation: in very small deployments, even thresholded aggregations may be re-identifiable

**Residual risk:** The minimum threshold is a heuristic, not a formal privacy guarantee. It does not provide differential privacy or k-anonymity. In deployments with 2-3 callers and distinctive usage patterns, thresholded aggregations may still be re-identifiable by someone with knowledge of the deployment's caller population. Formal privacy mechanisms are a v2 consideration.

---

### Threat 5: Replay Events Causing Inflated Metrics

**Stage:** Ingestion, Storage

**Scenario:** Events are delivered to the telemetry subscriber more than once — due to network retries, HookEmitter bugs, or intentional replay. Each duplicate delivery is stored as a separate event. Aggregations and metrics are inflated, showing higher invocation counts, different outcome distributions, and inaccurate latency statistics.

**Impact:** Incorrect operational metrics. False signals in gap-miner analysis. Operator decisions based on inflated data (e.g., tightening rate limits because metrics show higher usage than actually occurred).

**Mitigations:**
- V1 does not implement deduplication. This is a known limitation.
- The event envelope does not include a unique event ID — deduplication would require the upstream source to include one.
- Mitigation in v1 is operational: the HookEmitter is expected to deliver events exactly once. If the HookEmitter has retry logic, it is responsible for deduplication.
- V2 consideration: if the upstream source adds an event ID field, the telemetry layer can implement store-level deduplication.

**Residual risk:** Fully accepted in v1. Duplicate events will inflate metrics. The magnitude depends on the upstream source's delivery guarantees. This is documented as a known limitation.

---

### Threat 6: Storage Corruption from Concurrent Writes

**Stage:** Storage

**Scenario:** Multiple threads or processes write to the same JsonLinesStore simultaneously. Without coordination, concurrent writes can interleave — producing lines that are half one event and half another, corrupting both. Corrupted lines cannot be parsed during query or export, causing data loss or errors.

**Impact:** Data corruption in the durable store. Lost events. Errors during aggregation or export when corrupt lines are encountered.

**Mitigations:**
- File-level locking for JsonLinesStore writes — each write acquires an exclusive lock on the file before appending
- Atomic line writes — each event is serialized to a complete JSON line and written in a single operation
- MemoryStore uses Ruby's built-in thread safety for array operations (or a Mutex if needed)
- Corrupt line handling: the query/export path tolerates and skips unparseable lines, logging them as warnings

**Residual risk:** File locking protects against corruption but introduces contention under high concurrency. In very high-throughput, multi-threaded deployments, lock contention could slow writes. This is acceptable for v1 volumes. High-throughput deployments requiring lock-free writes should consider a different storage backend (v2 extension point).

---

### Threat 7: Configuration Tampering at Runtime

**Stage:** All stages (configuration affects every component)

**Scenario:** A buggy component, a malicious caller, or an accidental method call changes the telemetry configuration after startup. For example: the retention window is set to 0 (purge everything immediately), the storage size limit is set to infinity (unbounded growth), the metadata allowlists are emptied (all metadata stripped), or the privacy filter is disabled.

**Impact:** Any safety guarantee in this document can be voided by changing the configuration that enforces it. Runtime configuration tampering is a universal threat that undermines all other mitigations.

**Mitigations:**
- Immutable configuration after startup (Safety Rule 8) — the Configuration instance is frozen after initialization
- No setter methods, no reload commands, no hot-swap mechanism
- Ruby's `freeze` mechanism raises FrozenError on any modification attempt
- The only way to change configuration is to restart the process with new values

**Residual risk:** Ruby's `freeze` is a language-level protection, not a security boundary. Determined code can bypass freeze using `instance_variable_set` with appropriate access. However, this requires deliberate, explicit code to circumvent — accidental tampering and casual mutation are fully prevented.

---

### Threat 8: Downstream Consumer Coupling to Internal Storage Format

**Stage:** Export

**Scenario:** A downstream consumer (gap-miner or a custom tool) reads directly from the JsonLinesStore files instead of using the export pipeline. The consumer depends on internal field names, file naming conventions, or storage-level details. When the telemetry library upgrades and changes its internal format, the consumer breaks.

**Impact:** Fragile integration. Upgrade failures. Consumers that work with one version of the telemetry library and break with the next. In the worst case, the telemetry library cannot evolve its storage format because downstream consumers depend on the current format.

**Mitigations:**
- The export contract is the only supported interface (documented in `004-AT-STND-data-contracts.md`)
- Internal storage format is explicitly documented as unstable and subject to change without notice
- The export pipeline transforms stored data into the documented output format — it is not a pass-through
- Export schema versioning (semver) provides consumers with compatibility guarantees for the export interface
- File permissions and directory naming for internal storage are implementation details, not documented contracts

**Residual risk:** The telemetry library cannot prevent a consumer from reading its files directly. The mitigation is social and contractual (documentation, versioning, explicit warnings), not technical. A consumer that reads internal files is explicitly unsupported and accepts the risk of breakage.

---

## 4. Threat Summary Table

| # | Threat | Stage | Severity | Mitigated by |
|---|--------|-------|----------|-------------|
| 1 | PII leakage through metadata | Ingestion/Filter | High | Rules 3, 6; adversarial tests |
| 2 | Unbounded storage growth | Storage | High | Rule 4; configurable limits |
| 3 | Schema injection | Ingestion/Validation | Medium | Rule 2; type checking |
| 4 | Export re-identification | Aggregation/Export | Medium | Rule 7; population thresholds |
| 5 | Replay event inflation | Ingestion/Storage | Medium | Known limitation (v1) |
| 6 | Storage corruption | Storage | Medium | File locking; atomic writes |
| 7 | Configuration tampering | All | High | Rule 8; frozen config |
| 8 | Consumer coupling | Export | Low | Export contract; versioning |

---

## 5. Threat-to-Rule Mapping

Every safety rule in `005-TQ-STND-safety-model.md` mitigates at least one threat. Every threat is mitigated by at least one rule.

| Safety Rule | Mitigates Threats |
|------------|-------------------|
| Rule 1 (no raw params) | Threat 1 |
| Rule 2 (validate at ingestion) | Threats 3, 5 |
| Rule 3 (strip forbidden fields) | Threat 1 |
| Rule 4 (bound storage) | Threat 2 |
| Rule 5 (fire-and-forget) | (Operational safety — prevents Threat 2 from cascading) |
| Rule 6 (per-type allowlists) | Threat 1 |
| Rule 7 (no PII in aggregations) | Threat 4 |
| Rule 8 (immutable config) | Threat 7 |
