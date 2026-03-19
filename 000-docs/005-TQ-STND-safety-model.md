# wild-session-telemetry — Safety Model

**Document type:** Technical quality standard
**Filed as:** `005-TQ-STND-safety-model.md`
**Repo:** `wild-session-telemetry`
**Status:** Active — Phase 0 planning
**Last updated:** 2026-03-19
**Blueprint reference:** `001-PP-PLAN-repo-blueprint.md`

---

## 1. Purpose

This document defines the 8 safety rules that govern `wild-session-telemetry`. These are not guidelines — they are enforceable invariants. Every rule must have corresponding tests (including adversarial tests in Epic 8) that prove the rule holds.

The safety model for this repo is fundamentally different from admin-tools-mcp's. Admin-tools-mcp's safety challenge is governing mutation — preventing unauthorized writes. This repo's safety challenge is governing observation — ensuring that the data collected and exported never leaks private information, never grows without bound, and never disrupts the systems it observes.

A telemetry system that leaks private data is a liability. A telemetry system that grows without bound is an operational hazard. A telemetry system that disrupts its source is worse than no telemetry at all. These 8 rules prevent all three failure modes.

---

## 2. The Rules

### Rule 1: Never Store Raw Parameter Values from Pipeline Operations

**Statement:** The telemetry layer must never persist the actual parameter values passed to administrative operations. It captures that an operation happened, what type it was, and what outcome occurred — not what specific resources were operated on.

**Rationale:** Parameter values may contain application-specific identifiers, resource handles, or data that could be used to reconstruct what specific records, jobs, cache keys, or feature flags were acted upon. This level of detail belongs in the admin-tools-mcp audit trail, which is designed for forensic analysis with appropriate access controls. The telemetry layer is designed for operational pattern analysis and must not accumulate forensic-grade data.

**Enforcement:** The PrivacyFilter strips fields identified as parameter carriers (`params`, `parameters`, `arguments`, `args`, `input`, `request_body`) before storage. The event envelope schema does not include a parameter field. The per-event-type metadata allowlists do not include parameter-related keys.

**Test:** Adversarial test injects events with parameter values in various field names and positions. No parameter value survives to storage.

---

### Rule 2: Validate Event Schema at Ingestion Boundary, Reject Invalid Events Silently

**Statement:** Every incoming event must be validated against the known envelope schema before it is processed. Events that fail validation are silently dropped — no error is raised, no exception propagates, no error response is sent.

**Rationale:** Schema validation at ingestion is the first line of defense against malformed data, schema drift, and injection attacks. Silent rejection ensures that validation failures do not disrupt the event source. The HookEmitter should never be blocked, slowed, or errored by a telemetry validation failure.

**Enforcement:** The SchemaValidator checks every event for: required fields present, correct field types, known event_type value, known outcome value, valid timestamp format, non-negative duration_ms. Events failing any check are dropped before reaching the privacy filter or store.

**Test:** Unit tests submit events with every category of validation failure (missing fields, wrong types, unknown event types, invalid timestamps). None reach storage. The caller receives no error.

---

### Rule 3: Strip Unknown/Forbidden Fields Before Storage (Defense in Depth)

**Statement:** Even after schema validation, the privacy filter must strip any field that is not on the approved list for the event type. This is defense in depth — it protects against cases where the upstream source adds new fields that pass the envelope schema but contain data that should not be stored.

**Rationale:** Schema validation confirms the envelope is well-formed. Privacy filtering confirms the content is appropriate. These are independent checks. A well-formed event can still contain forbidden data in its metadata. Defense in depth means both checks must pass, and neither is sufficient alone.

**Enforcement:** The PrivacyFilter operates in two layers: (1) global exclusion of known forbidden field patterns; (2) per-event-type metadata allowlisting that strips any key not explicitly approved. Both layers execute on every event, in sequence, before the event reaches the store.

**Test:** Adversarial tests inject events that pass schema validation but contain forbidden metadata keys, unknown metadata keys, and deeply nested structures. All unapproved content is stripped.

---

### Rule 4: Bound Storage Growth with Configurable Retention and Size Limits

**Statement:** The telemetry store must never grow without bound. Time-based retention purges old events. Size-based limits cap total storage consumption. Both are configurable at startup with sensible defaults.

**Rationale:** Unbounded storage growth is the most common operational failure mode for telemetry systems. It happens slowly, over weeks or months, until disk fills or memory is exhausted. Configurable limits with default values ensure that even an unconfigured deployment has bounded storage.

**Enforcement:** MemoryStore enforces a maximum event count (default 100,000). JsonLinesStore enforces a maximum storage size (default 1 GB). Both stores enforce time-based retention (default 90 days). Purge runs opportunistically during store operations and can be triggered explicitly.

**Test:** Tests fill the store beyond limits and verify that purge activates. Tests verify that storage size does not exceed configured maximums. Tests verify that old events are purged after the retention window.

---

### Rule 5: Fire-and-Forget Semantics — Telemetry Failures Never Propagate to Callers

**Statement:** No error, exception, or failure within the telemetry system may propagate to the caller of `receive(event)`. The telemetry subscriber is fire-and-forget. If it fails internally, it fails silently.

**Rationale:** The telemetry subscriber attaches to admin-tools-mcp's HookEmitter. If the subscriber raises an exception, the HookEmitter's behavior depends on its error handling — at best it logs the error, at worst it stops calling subscribers. Either way, the admin-tools-mcp pipeline is disrupted by a telemetry failure. This is unacceptable. Telemetry is an observer, not a participant. Its failures must be invisible to the observed system.

**Enforcement:** The `receive(event)` method wraps all internal processing in a rescue-all block. Internal errors are counted (for health monitoring) but never raised. The method always returns nil, regardless of success or failure.

**Test:** Tests inject conditions that cause internal failures (store full, file system error, validation bug). The `receive(event)` call completes without raising. The caller observes no change in behavior.

---

### Rule 6: Per-Event-Type Metadata Allowlisting — Only Known Fields Pass Through

**Statement:** Each event type has an explicit, hardcoded allowlist of metadata keys. Only metadata keys on the allowlist for the event's type are stored. All other metadata keys are stripped, regardless of their content.

**Rationale:** Metadata is the highest-risk field in the event envelope. It is a Hash that can contain arbitrary keys and values. Without allowlisting, any field that the upstream source adds to metadata reaches storage — including fields that contain private data. Per-type allowlisting ensures that the telemetry layer's data surface is explicitly controlled, not implicitly inherited from the upstream source.

**Enforcement:** The PrivacyFilter maintains a hardcoded mapping of event_type to allowed metadata keys. During filtering, only keys present in the mapping for the event's type survive. The mapping is defined in code, not configuration — updating it requires a code change and review.

**Test:** Tests submit events with metadata containing both allowed and forbidden keys. Only allowed keys survive. Tests verify that the allowlist is not configurable at runtime or startup.

---

### Rule 7: No PII in Export Aggregations — Aggregations Must Not Enable Re-Identification

**Statement:** Export aggregations (session summaries, tool utilization, outcome distributions, latency statistics) must not enable re-identification of individual callers or individual operations when the population is above the minimum threshold.

**Rationale:** Aggregation over small populations can effectively identify individuals. If only one caller uses a specific action, the per-action aggregation reveals that caller's usage pattern. This is a well-known privacy risk in analytics systems. The telemetry layer mitigates it with minimum population thresholds — aggregations below the threshold are suppressed from export.

**Enforcement:** Aggregation output includes a record only if the underlying event population meets the configured minimum threshold (default: 5 events). Session summaries with fewer events than the threshold are suppressed. Tool utilization records with fewer invocations than the threshold are suppressed.

**Test:** Tests create aggregation scenarios with small populations (1 caller, 1 event). Verify that aggregation records are suppressed. Tests create scenarios just above the threshold. Verify records appear. Adversarial tests attempt to extract individual caller patterns from aggregation output.

---

### Rule 8: Immutable Configuration After Startup — No Runtime Reconfiguration

**Statement:** All configuration parameters are set at startup and frozen. There is no mechanism to change configuration at runtime — no setter methods, no reload commands, no hot-swap.

**Rationale:** Runtime reconfiguration is a tampering vector. If an attacker (or a buggy agent) can change the retention window, disable the privacy filter, or modify the metadata allowlists at runtime, every safety guarantee in this document is void. Immutable configuration eliminates this attack surface entirely. The only way to change configuration is to restart the process with new configuration.

**Enforcement:** The Configuration class freezes all values after initialization. Setter methods do not exist. Internal references to configuration values go through the frozen Configuration instance. Any attempt to modify configuration after initialization raises a FrozenError.

**Test:** Tests attempt to modify configuration after initialization via every available interface (direct assignment, method calls, instance variable manipulation). All attempts fail. Tests verify that the Configuration instance is frozen.

---

## 3. Rule Summary Table

| # | Rule | Primary threat mitigated |
|---|------|------------------------|
| 1 | Never store raw parameter values | PII/data leakage through operational metadata |
| 2 | Validate schema at ingestion, reject silently | Malformed data, schema injection |
| 3 | Strip unknown/forbidden fields (defense in depth) | Schema drift, new fields leaking private data |
| 4 | Bound storage growth | Unbounded disk/memory consumption |
| 5 | Fire-and-forget semantics | Telemetry disrupting observed systems |
| 6 | Per-event-type metadata allowlisting | Arbitrary data reaching storage via metadata |
| 7 | No PII in export aggregations | Re-identification from small populations |
| 8 | Immutable configuration after startup | Runtime tampering with safety controls |

---

## 4. Relationship to Other Safety Documents

- **`003-TQ-STND-privacy-model.md`** defines what data is collected and excluded. This document defines the rules that enforce those decisions.
- **`006-AT-ADEC-threat-model.md`** identifies threats. This document defines the rules that mitigate them.
- **`007-AT-ADEC-architecture-decisions.md`** documents design choices. Several of those choices exist to support these rules.

Every rule in this document must be traceable to at least one threat in the threat model and at least one test in the adversarial testing epic.
