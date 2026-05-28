# wild-session-telemetry — Operator-Grade System Audit

**Document type:** Architecture audit
**Filed as:** `014-AT-AUDT-appaudit-2026-05-28.md`
**Repo:** `wild-session-telemetry` (v0.1.0)
**Audience:** Senior Rails/Ruby engineer, first read, under pressure
**Time-to-operate target:** 10 minutes
**Last updated:** 2026-05-28

---

## 1. Mission & Boundaries

`wild-session-telemetry` is a **pure Ruby library gem** (no server, no MCP, no ActiveRecord) that ingests structured operational events emitted by sibling repos in the `wild` ecosystem (primarily `wild-admin-tools-mcp`), validates them, strips PII-shaped data, persists them to a local store, and produces JSON Lines exports for downstream consumers (`wild-gap-miner`, secondarily `wild-transcript-pipeline`). The library is one of 10 gems in the ecosystem; ecosystem-level rules live at `../CLAUDE.md`. The repo CLAUDE.md classifies it as Archetype B — data pipeline / analytics.

**What is collected** (the storage envelope, defined in `lib/wild_session_telemetry/schema/event_envelope.rb:7-37`):

| Field | Purpose |
|---|---|
| `event_type` | One of `action.completed`, `gate.evaluated`, `rate_limit.checked` |
| `timestamp` | ISO 8601 time at the upstream source |
| `caller_id` | Service-account or operator-role identifier (not a natural person) |
| `action` | Operation name |
| `outcome` | One of `success`, `denied`, `error`, `preview`, `rate_limited` |
| `duration_ms` | Latency in milliseconds |
| `metadata` | Per-event-type allowlisted keys only |
| `received_at` | Auto-generated ingestion timestamp |
| `schema_version` | Defaults to `'1.0'` |

**What is explicitly NOT collected** (specification in `000-docs/003-TQ-STND-privacy-model.md` §4; enforcement in `lib/wild_session_telemetry/privacy/filter.rb:14-20`):

- Raw parameter values (`params`, `parameters`, `arguments`, `args`, `input`, `request_body`)
- Before/after state snapshots (`before_state`, `after_state`, `snapshot`, etc.)
- Confirmation nonces or tokens (`nonce`, `token`, `confirmation_token`)
- Stack traces (`backtrace`, `stacktrace`, `error_trace`)
- Adapter-specific identifiers (Sidekiq `jid`, Redis IDs, GoodJob `execution_id`, internal DB IDs)
- Any complex value (Array, Hash) inside `metadata` — only scalars survive

**Explicit non-goals** (`CLAUDE.md` "What This Repo Does NOT Do"): no MCP server, no dashboard, no PII collection in any form, no transcript normalization (that is `wild-transcript-pipeline`), no gap analysis (that is `wild-gap-miner`), no generic event bus, no real-time pub/sub. Upstream emitters push events fire-and-forget; the library is a subscriber.

**Privacy guarantees in one paragraph.** Allowlisting is hardcoded, not configurable — there is no runtime knob to weaken privacy. Configuration is frozen after `WildSessionTelemetry.configure` returns (`lib/wild_session_telemetry/configuration.rb:34-36`). The filter runs *before* the validator runs *before* the store (`collector/event_receiver.rb:12-19`). Any code path that reaches storage went through the filter — there is no bypass. The eight privacy invariants are enumerated in `003-TQ-STND-privacy-model.md` §9 and exercised by `spec/adversarial/privacy_invariants_spec.rb`.

---

## 2. Collection Architecture

The library is structured as **eight modules under a flat `WildSessionTelemetry` namespace** (architecture decision 3 in `007-AT-ADEC-architecture-decisions.md`). The eager `require` block at `lib/wild_session_telemetry.rb:3-18` loads every module at gem load time — there is no lazy autoload, which means every component is in memory the moment the host application calls `require 'wild_session_telemetry'`.

**Module map** (lib paths relative to `lib/wild_session_telemetry/`):

| Module | File | Role |
|---|---|---|
| `Configuration` | `configuration.rb` | Singleton config object; frozen post-`configure` |
| `Schema::EventEnvelope` | `schema/event_envelope.rb` | Immutable validated event record (plain Ruby `class` with `freeze`, **not** `Data.define` as decision 7 claims — see §9) |
| `Schema::Validator` | `schema/validator.rb` | Schema enforcement: required fields, enum values, ISO-8601 pattern, type checks |
| `Privacy::Filter` | `privacy/filter.rb` | Top-level key strip → forbidden-name strip → per-type allowlist → value-type sanitize |
| `Collector::EventReceiver` | `collector/event_receiver.rb` | The `receive(event)` boundary the upstream pushes into |
| `Store::Base` / `MemoryStore` / `JsonLinesStore` | `store/*.rb` | Pluggable backends behind a 6-method interface |
| `Store::RetentionManager` | `store/retention_manager.rb` | Time-based + size-based purge (only operates on `JsonLinesStore`) |
| `Store::StorageMonitor` | `store/storage_monitor.rb` | Health checks + `stats` |
| `Aggregation::Engine` | `aggregation/engine.rb` | Session summaries, tool utilization, outcome distribution, latency percentiles |
| `Aggregation::PatternDetector` | `aggregation/pattern_detector.rb` | Sequence + failure-cascade pattern mining |
| `Export::RecordBuilder` + `Export::Exporter` | `export/*.rb` | Produce JSON Lines with a header + typed records |

**How collection runs without blocking the request path.** Three structural choices, in combination:

1. **In-process method call, not a network hop.** `EventReceiver#receive` is a plain Ruby method invocation (decision 1). No socket, no queue. A no-op call (one that fails validation) returns `nil` almost instantly — the slowest path on a successful ingest is one filter pass, one validator pass, one `EventEnvelope.new`, and one `store.append`.
2. **Fire-and-forget semantics enforced at the boundary.** `EventReceiver#receive` wraps the entire ingest in `rescue StandardError` and returns `nil` (`collector/event_receiver.rb:20-22`). The upstream caller never sees an exception, never sees a stack trace, never has its own control flow perturbed by telemetry being misconfigured, full, or broken.
3. **No background threads, no executors, no queues.** The library does not spawn workers. There is no async buffer between `receive` and `store.append`. The "buffer" is the store itself — `MemoryStore` is a `Mutex`-protected in-process array (`store/memory_store.rb:8-9`); `JsonLinesStore` is a `Mutex`-protected `File.open(path, 'a')` append (`store/json_lines_store.rb:18-24`). Each `receive` call performs synchronous, durable I/O on the request path.

**Implication operators must understand.** This is the single most important characteristic of the design and the one operators must internalize before deploying: **there is no async buffer**. Every event your application emits triggers a synchronous filesystem append (in the `JsonLinesStore` path). The `Mutex` serializes writers within a process. Threat model 6 (`006-AT-ADEC-threat-model.md` §3.6) acknowledges the contention risk and accepts it for v1 volumes — "thousands to tens of thousands of events." Beyond that, lock contention on a single file becomes the bottleneck, and the v2 roadmap (`011-PP-PLAN-v2-expansion-roadmap.md` §2.1) lists `SqliteStore` and `RedisStore` as candidate alternatives. The `fire-and-forget` rescue prevents an exception from escaping; it does not prevent latency from being added to the caller. If the disk hangs, the caller hangs.

There are no samplers, no head/tail-based sampling, and no rate-limited drop policy in v1. Every event the validator accepts is stored. Reduction happens later — either at retention time (purge), or at aggregation time (population thresholds), or at export time (filter parameters). The trade-off is documented at decision 5 (independent ingestion and export subsystems).

---

## 3. The Critical Path

Trace one event end-to-end. This is the canonical path a senior engineer should be able to recite from memory after a single read.

**Step 1 — Upstream instrumented call.** `wild-admin-tools-mcp` (the primary emitter, per `004-AT-STND-data-contracts.md` §2) completes an admin operation and calls `receiver.receive(event_hash)` on its registered subscriber. The subscriber object is an instance of `WildSessionTelemetry::Collector::EventReceiver`. `event_hash` is a plain Ruby `Hash` matching the event envelope schema. The upstream caller cannot rely on any return value — `receive` returns the stored `EventEnvelope` on success and `nil` on any failure or rejection. The contract guarantees no exception escapes.

**Step 2 — Privacy filter (defense in depth, runs first).** `Privacy::Filter#filter` (`privacy/filter.rb:24-29`) executes four passes in order:

1. `normalize` — `transform_keys(&:to_sym)` so the rest of the pipeline can use symbol access.
2. `strip_top_level` — `event_hash.slice(*ALLOWED_TOP_LEVEL_KEYS)` drops any top-level key not on the seven-entry allowlist.
3. `filter_metadata` — for each event type, look up the per-type allowlist in `METADATA_ALLOWLISTS`, drop forbidden names (`FORBIDDEN_FIELD_NAMES`), then `.slice` to only the allowlisted keys. **An event with an unknown `event_type` falls through `fetch(event_type, [])`, producing an empty allowlist, which strips all metadata** — by design, not a bug.
4. `sanitize_metadata_values` — drop any metadata value that is not a `String`, `Integer`, `Float`, `TrueClass`, `FalseClass`, or `NilClass`.

**Step 3 — Schema validator.** `Schema::Validator#validate` (`schema/validator.rb:11-23`) returns a `[boolean, errors]` tuple. It enforces required fields (`event_type`, `timestamp`, `caller_id`, `action`, `outcome`), known-value enums for `event_type` and `outcome`, ISO-8601 prefix match on `timestamp`, numeric type on `duration_ms`, Hash type on `metadata`. If invalid, `receive` returns `nil` and the event is silently dropped (no log line at the library boundary — see §6 for the gap).

**Step 4 — Envelope construction.** `Schema::EventEnvelope.from_raw(filtered)` (`schema/event_envelope.rb:39-50`) builds an immutable instance. The constructor freezes `metadata` then freezes the whole object (`event_envelope.rb:22`). `received_at` is auto-stamped here if absent.

**Step 5 — Store append.** `store.append(envelope)` — `Mutex`-synchronized array push for `MemoryStore`, `Mutex`-synchronized `File.open(@path, 'a') { |f| f.puts(line) }` for `JsonLinesStore`. Returns the envelope.

**Step 6 — Aggregate (on demand).** Aggregation is not in the ingest path. It runs only when `Aggregation::Engine` is called against a slice of stored events — typically from `Export::Exporter#export` (`export/exporter.rb:36-46`). The engine computes session summaries, tool utilization, outcome distributions, and latency percentiles, suppressing any bucket below `min_population` (default 5).

**Step 7 — Serialize and export.** `Exporter#export` returns an **array of pre-serialized JSON strings** (`export/exporter.rb:25-27`), with the header at `lines.first`. The caller is responsible for writing those strings to a file (the recommended idiom is shown in `010-OD-GUID-operator-workflow-guide.md` §4.4). The export operation is read-only against the store — it does not mutate, purge, or modify stored events.

Latency budget for one ingest, dominated by step 5: one mutex acquire + one `File#puts` on `JsonLinesStore`, or one mutex acquire + one array `<<` on `MemoryStore`.

---

## 4. Privacy Posture

The privacy story is the single most defensible part of this codebase. It is layered, hardcoded, and tested adversarially.

**What scrubs PII.** `Privacy::Filter` at `lib/wild_session_telemetry/privacy/filter.rb`, exercised by `spec/wild_session_telemetry/privacy/filter_spec.rb` and the harder `spec/wild_session_telemetry/privacy/filter_hardening_spec.rb`. The filter runs unconditionally before storage. The receiver constructs a default filter if the caller does not inject one (`collector/event_receiver.rb:9`), so there is no way to ingest without filtering through normal use.

**What is redacted by default.** Five defense layers, in order of application:

| Layer | Mechanism | Constants location |
|---|---|---|
| Top-level keys | `slice(*ALLOWED_TOP_LEVEL_KEYS)` keeps 7 envelope keys; everything else is dropped | `filter.rb:6` |
| Forbidden names | `except(*FORBIDDEN_FIELD_NAMES)` strips 23 known-bad names from metadata regardless of allowlist match | `filter.rb:14-20` |
| Per-type allowlists | `slice(*allowed_keys)` keeps only the 2–6 keys explicitly approved for the event type | `filter.rb:8-12` |
| Value types | `select { ALLOWED_VALUE_TYPES.any? }` strips arrays, hashes, custom objects from metadata values | `filter.rb:22` |
| Unknown event types | Implicit — `METADATA_ALLOWLISTS.fetch(event_type, [])` returns `[]`, stripping all metadata | `filter.rb:46` |

**Opt-in vs opt-out.** Collection is strictly opt-in (privacy model §7.1): the host application must explicitly construct a receiver and attach it to the upstream emitter. There is no autoloader, no Rails initializer, no hook the gem installs on require. If the application does not wire it up, no events are collected. There is also no external transmission (privacy model §7.3) — exports are local file operations the operator controls. If exports are uploaded to a cloud service, that is the operator's choice, outside the library's scope.

**Aggregation privacy.** `Aggregation::Engine` enforces a `min_population` threshold (default 5, `aggregation/engine.rb:8`) on every aggregation method via `next if bucket.size < @min_population`. Buckets below the threshold are silently dropped — they never appear in the export. This is explicitly described as a **heuristic, not a cryptographic guarantee** (`003-TQ-STND-privacy-model.md` §8.3 and threat 4 in `006-AT-ADEC-threat-model.md`). In deployments with very few callers or very distinctive workload patterns, even thresholded aggregations may be re-identifiable. Differential privacy is on the v2 roadmap, not in v1.

**Documented residual risk** (threat 1, `006-AT-ADEC-threat-model.md` §3.1). Allowlisting is by key *name*, not value *content*. If an upstream emitter puts an email address into the `category` field (which is allowlisted for `action.completed`), the email lands in storage. Value-level PII pattern scanning is explicitly v2 scope (`011-PP-PLAN-v2-expansion-roadmap.md` §2.5). This limitation is the single most important caveat to communicate to upstream emitter authors.

**Specs that pin the invariants.** `spec/adversarial/privacy_invariants_spec.rb`, `spec/adversarial/threat_mitigations_spec.rb`, `spec/adversarial/safety_rules_spec.rb` and `spec/wild_session_telemetry/privacy/filter_hardening_spec.rb`. The eight invariants enumerated in `003-TQ-STND-privacy-model.md` §9 are each backed by tests.

---

## 5. Data Contract for Downstream Consumers

The output contract is the **single stable interface** the library publishes to the world. It is documented in `000-docs/004-AT-STND-data-contracts.md` §4 and produced by `lib/wild_session_telemetry/export/exporter.rb` + `lib/wild_session_telemetry/export/record_builder.rb`.

**Wire format.** JSON Lines. First line is a header. Each subsequent line is a self-contained JSON object carrying a `record_type` tag. Generated by `Exporter#build_header` (`export/exporter.rb:58-70`):

```json
{
  "export_type": "session_telemetry",
  "schema_version": "1.0.0",
  "exported_at": "2026-03-19T15:00:00.000Z",
  "time_range": { "start": "...", "end": "..." },
  "record_counts": { "events": 1523, "session_summary": 47, ... }
}
```

**Record types and their canonical builders** (`export/record_builder.rb`):

| `record_type` | Builder method | Source data |
|---|---|---|
| `event` | `event_record` (line 19) | Filtered envelope fields from `EventEnvelope#to_h` |
| `session_summary` | `session_summary_record` (line 25) | `Engine#session_summaries` per-caller per-window roll-up |
| `tool_utilization` | `tool_utilization_record` (line 29) | `Engine#tool_utilization` per-action stats |
| `outcome_distribution` | `outcome_distribution_record` (line 33) | `Engine#outcome_distributions` per-action breakdown |
| `latency_stats` | `latency_stats_record` (line 37) | `Engine#latency_stats` p50/p95/p99 |
| `pattern` | `pattern_record` (line 41) | `PatternDetector#detect_sequences` and `detect_failure_cascades` |

**What consumers can depend on** (`004-AT-STND-data-contracts.md` §6.1): the JSON Lines wire format, the record types and their fields (within a major schema version), the `schema_version` semver in the header, the `receive(event)` interface, and the fire-and-forget guarantee.

**What consumers must NOT depend on** (`004-AT-STND-data-contracts.md` §6.2): internal storage paths, the internal JSONL stored-event format, `MemoryStore`'s in-process layout, file rotation strategy (none exists in v1 — see §7), record order within an export beyond "header is first", and the aggregation/pattern algorithms (output shape is stable; computation may change).

**The contract document is one-sided.** Schema ownership is asserted in `004-AT-STND-data-contracts.md` §6.3: "Export schema — owner `wild-session-telemetry`, consumer `wild-gap-miner`. Telemetry owns schema; gap-miner depends on it." This is correctly recorded *here*. On the gap-miner side (`/home/jeremy/000-projects/wild/wild-gap-miner/000-docs/006-OD-GUID-operator-workflow-guide.md` lines 16-25), the consumer documents that it expects `export_type: "session_telemetry"` as the header marker and "typed records" on subsequent lines, but does not pin a specific schema version or quote the record-type field set. **Drift risk: when v1's `schema_version` bumps minor (new optional record types per the semver policy in §5.1), gap-miner's spec does not say what it does with unrecognized record types.** That's an open contract question between the two repos.

**Concrete cross-repo gap (HIGH).** `wild-gap-miner`'s operator guide (lines 19-21) instructs operators to run `wst export --from 2025-01-14 --to 2025-01-15 --output /tmp/telemetry.jsonl`. **No `wst` CLI exists in this repo.** The gemspec declares no executables; there is no `bin/wst`; the only export interface is the Ruby `Export::Exporter#export` method, which returns an array of strings the caller must `File.open` and write. Either the CLI needs to be built here (recommended — see §9), or the gap-miner doc needs to be amended to show the Ruby-API invocation. Today an operator following the gap-miner guide hits a `command not found`.

---

## 6. Failure Modes & Blast Radius

**Buffer fills (memory or disk).** There is no in-memory buffer. The "buffer" is the store itself.

- `MemoryStore`: the array grows unbounded. The CLAUDE.md safety rule 4 ("Bound storage growth") asserts a `max_memory_events` limit, and `008-DR-REFF-configuration-reference.md` §6.4 documents a default of 100,000 — but **the current `MemoryStore` implementation has no eviction logic** (`store/memory_store.rb` has no size check on `append`). If you use `MemoryStore` in a long-running process, RAM grows with event count until the process is killed. This is a documented-but-unimplemented invariant.
- `JsonLinesStore`: the file grows unbounded until the operator calls `RetentionManager#purge_oversized` (`store/retention_manager.rb:24-29`). There is no opportunistic purge inside `append`. Threat 2 mitigation §2.3.6 claims "opportunistic purge during write operations — every write checks whether purge is needed" — that claim is currently aspirational; the production code does not implement it. Disk fills until the operator's cron-driven purge runs.

**Export endpoint unreachable.** Not applicable — there is no network export. Export writes to a local file the operator chooses. If the operator's downstream pipeline (an S3 upload, a `wild-gap-miner` invocation) fails, telemetry is not aware. The local file persists; the operator retries.

**PII scrub fails (or "fails open").** The `Privacy::Filter` does not raise — it returns the filtered hash unconditionally. If a filter pass receives malformed input (e.g., metadata that is not a Hash), `filter_metadata` returns the event unchanged (`filter.rb:43`) and `sanitize_metadata_values` does the same. The validator then catches the structural problem (metadata must be a Hash) and rejects the event. So the filter does not fail open; the validator is the second gate. The combined behavior: events with structural problems are dropped, not stored with bypassed scrubbing.

**The receiver swallows everything.** `EventReceiver#receive` ends with `rescue StandardError; nil; end` (`collector/event_receiver.rb:20-22`). This catches every `StandardError` — file I/O errors on store append, `JSON::ParserError` somewhere, anything. The caller sees `nil`. **There is no stderr log, no `Logger` call, no metric incremented.** Operators have *no signal* that ingestion is failing other than a flat or stale `monitor.stats[:event_count]`. The operator playbook (§8.1 of the workflow guide) documents this — "Exceptions being swallowed | `receive` rescues all `StandardError` | Check stderr/logs for exception output" — but in fact nothing is written to stderr. This is the largest operability gap in v1 (see §9 recommendations).

**Error classes** (`lib/wild_session_telemetry/errors.rb`): `Error`, `ValidationError`, `SchemaError`, `ConfigurationError`, `StorageError`. All inherit from `StandardError`. **None of them are raised anywhere in the production code.** They exist as a placeholder API for future external use. The receiver does not raise; the validator returns a tuple; the store does not raise on append; the filter does not raise. This means the entire library currently has a zero-exception contract — convenient for fire-and-forget, opaque for debugging.

**Blast radius.** Confined to the host process. Telemetry cannot cascade to the upstream caller (`rescue` boundary), cannot push errors to a network endpoint (no network), cannot trigger pagers (no logger). The only externally visible blast radius is: disk exhaustion on the host filesystem (if `JsonLinesStore` is used and `RetentionManager` is not scheduled), or RAM exhaustion (if `MemoryStore` is used in a long-running process).

---

## 7. Trade-off Analysis

| # | Decision | Chosen | Alternative | Why | Cost | When it breaks |
|---|---|---|---|---|---|---|
| 1 | Ingest blocking model | Synchronous in-process call, no queue, no thread pool (`event_receiver.rb`) | Background thread + bounded queue OR external broker | Minimal latency; zero operational overhead; matches `HookEmitter`'s `receive(event)` contract (decision 1) | Caller's request thread blocks on filesystem append (~ms on healthy disk; unbounded on stalled disk). `Mutex` serializes writers within process. | High-throughput multi-threaded Rails apps where many threads emit concurrently and disk latency spikes. Lock contention turns telemetry into a request-path bottleneck. v2 roadmap lists `RedisStore` / `SqliteStore` as escape hatches. |
| 2 | Persistence format | One JSON object per line in a single `.jsonl` file (`json_lines_store.rb`) | SQLite, Redis, custom binary, rotating-file scheme | Pure Ruby; no native extensions; trivial to read with `tail -f`, `jq`, or any text tool; matches admin-tools-mcp's audit-trail pattern (decision 2) | Every query is a full file scan (`File.foreach`). `count` walks the entire file. Aggregations re-read the file for each `Engine` method call. No indexing, no file rotation in v1. | Once the file is large enough that a full scan is too slow for the export cadence (rough heuristic: tens of MB per export on commodity disk). Operators must run `RetentionManager` aggressively to keep the file small. |
| 3 | Configuration mutability | Frozen after `configure` returns; modification raises `FrozenError` (`configuration.rb:34-36`) | Hot-reload, runtime setters, admin endpoint | Eliminates threat 7 (config tampering at runtime); makes the system's behavior provably constant from process start to shutdown | Every config change requires a process restart, including emergency changes like "reduce retention because disk is full" | Incident response where you need to shrink the retention window without bouncing the process. Operational mitigation: scripted restarts; build retention with margin so emergencies are rare. |
| 4 | Schema validation locus | At ingestion only; export trusts the store (`event_receiver.rb` calls validator; `exporter.rb` does not re-validate) | Validate at both ingest and export | Fail-early; storage is the authoritative clean layer; export is a pure transformation (decision 4) | If a validator bug ever permits invalid data through, every export that touches those records is contaminated. Recovery requires manual scrub + re-export. | When the schema evolves and a migration introduces transient invalid data. Mitigation: comprehensive adversarial validator tests (present); add a `--strict` export mode in v2 that re-validates as defense in depth. |
| 5 | Aggregation timing | On-demand at export time; nothing pre-computed (`exporter.rb:36-46` invokes engine per export) | Streaming aggregation maintained at ingest; nightly batch pre-aggregation | Independent ingest/export subsystems (decision 5); ingest stays fast; no wasted CPU when nobody is exporting | Export latency scales with the size of the queried window — re-walks events, re-groups, re-percentiles every time | Reporting workloads that export the same window repeatedly (dashboards). Mitigation v2: caching layer or materialized aggregation table per window. |
| 6 | Failure visibility | Silent — `rescue StandardError; nil; end` swallows all exceptions; no logger; no metric (`event_receiver.rb:20-22`) | Log to `Logger` on swallow; emit a `dropped_events_total` counter; sentinel return for distinguishing "rejected" from "errored" | Honors fire-and-forget contract; zero impact on upstream caller path | Operators cannot distinguish "no events flowing because nothing is happening" from "no events flowing because the disk is read-only and every write is silently failing" | Production incidents. This is the highest-leverage v2 fix (see §9). |
| 7 | Privacy filtering model | Allowlist by key name; value-content not inspected (`filter.rb`) | Regex-based value scanning for PII patterns (email, phone, SSN, JWT) | Practical for v1 — covers structural leaks (forbidden field names) which are the dominant case; avoids the complexity and false-positive rate of value-content inspection | Documented residual risk: a PII value smuggled into an allowlisted field (e.g., email in `category`) reaches storage | When an upstream emitter is buggy or hostile and uses an allowlisted key as a vector. Mitigation: upstream-side discipline + adversarial review of new emitters before they're wired in. Value-level scanning is on the v2 roadmap. |

---

## 8. Operator Playbook

**Configure collection (Rails initializer):**

```ruby
# config/initializers/wild_session_telemetry.rb
require 'wild_session_telemetry'

WildSessionTelemetry.configure do |config|
  config.store = WildSessionTelemetry::Store::JsonLinesStore.new(
    path: '/var/data/wild-telemetry/telemetry.jsonl'
  )
  config.retention_days    = 90
  config.privacy_mode      = :strict
  config.max_storage_bytes = 1_073_741_824  # 1 GB
end

WST_RECEIVER = WildSessionTelemetry::Collector::EventReceiver.new(
  store: WildSessionTelemetry.configuration.store
)

# Then in your upstream HookEmitter:
#   hook_emitter.subscribe(WST_RECEIVER)
```

Per `009-OD-OPNS-operator-deployment-guide.md`. Important: the configure block freezes config on return. Any later mutation raises `FrozenError`.

**Inspect buffered (stored) events:**

```ruby
monitor = WildSessionTelemetry::Store::StorageMonitor.new(store: WildSessionTelemetry.configuration.store)
monitor.healthy?            # => true / false
monitor.stats               # => {event_count:, size_bytes:, oldest_event:, newest_event:, store_type:}
WildSessionTelemetry.configuration.store.recent(limit: 50)
WildSessionTelemetry.configuration.store.query(event_type: 'action.completed', since: '2026-05-27T00:00:00Z')
```

Or shell-side against the `.jsonl` file (the format is stable enough for grep/jq even though §6.3 of the data-contracts doc says consumers shouldn't depend on it — for ad-hoc inspection it's fine):

```bash
tail -n 50 /var/data/wild-telemetry/telemetry.jsonl | jq .
jq -r 'select(.outcome=="error") | [.timestamp,.caller_id,.action] | @tsv' /var/data/wild-telemetry/telemetry.jsonl
```

**Drain manually (produce an export):**

```ruby
exporter = WildSessionTelemetry::Export::Exporter.new(
  store: WildSessionTelemetry.configuration.store,
  aggregator: WildSessionTelemetry::Aggregation::Engine.new(min_population: 5),
  pattern_detector: WildSessionTelemetry::Aggregation::PatternDetector.new
)
lines = exporter.export(since: '2026-05-21T00:00:00Z', before: '2026-05-28T00:00:00Z')
File.open('/var/data/exports/telemetry-2026-05-28.jsonl', 'w') { |f| lines.each { |l| f.puts l } }
```

Hand the resulting file to `wild-gap-miner`. **The `wst export ...` CLI that gap-miner's operator guide references does not exist in this repo** (see §5 cross-repo gap).

**Recover from export failure.** Export is a pure read of the store. If `export` raises, the store is unaffected. Common causes: filesystem permissions on the destination directory, disk full, malformed query parameters (the export accepts whatever the store accepts — invalid filters just return zero rows). Re-run with corrected parameters. The store retains all events until `RetentionManager` purges them.

**Recover from ingestion failure.** This is the harder case because failures are silent (§6). Diagnose by:

1. `monitor.stats[:newest_event]` — if stale, ingestion is paused or broken.
2. Bypass the receiver and run the filter + validator manually on a test event (workflow guide §8.1 has the recipe).
3. Check filesystem permissions on the `JsonLinesStore` path.
4. Check disk fullness on the store volume.
5. Restart the application — if ingestion resumes after restart, suspect a stuck mutex (rare but possible if a prior write thread died holding it; Ruby's `Mutex` is process-local so a crash should release it).

**Routine retention sweep** (cron or systemd timer):

```ruby
manager = WildSessionTelemetry::Store::RetentionManager.new(
  store: WildSessionTelemetry.configuration.store,
  retention_days: 90,
  max_size_bytes: 1_073_741_824
)
removed = manager.purge_all
$stderr.puts "telemetry purge: removed #{removed} events"
```

Cadence per `010-OD-GUID-operator-workflow-guide.md` §7.5: weekly for low volume, daily for medium, every 6 hours for high.

---

## 9. Recommendations for v2

**Critical (operability).**

1. **Add a `Logger` hook to the swallowing `rescue` in `EventReceiver`.** Today every failure is invisible. At minimum, log to `$stderr` with the exception class and message. Better: accept an injectable `logger:` on construction and call `logger.warn` on each swallow. Without this, operators have no signal short of "events stopped flowing." This is the single highest-leverage change in v2.
2. **Emit a `dropped_events_total` counter** (or expose a `EventReceiver#dropped_count` reader). Pairs with #1 — gives operators a metric they can alert on.
3. **Build the `wst` CLI** that `wild-gap-miner`'s operator guide assumes exists. A thin Thor wrapper around `Exporter#export` with `--from`, `--to`, `--event-type`, `--caller-id`, `--output` flags. Until this exists, the documented gap-miner workflow doesn't work out of the box.

**Important (correctness).**

4. **Implement the `MemoryStore` size cap that the spec documents.** `003-TQ-STND-privacy-model.md` §6.4 and CLAUDE.md safety rule 4 promise a 100,000-event cap. The code has none. Either implement it (FIFO eviction on `append`) or amend the spec to admit `MemoryStore` is dev/test-only.
5. **Implement opportunistic purge or amend threat 2 mitigation.** Threat 2 §2.3.6 claims "opportunistic purge during write operations" — the code does not do this. Either add a counter that triggers `purge_oversized` every N appends, or remove the claim from the threat model.
6. **Reconcile `Data.define` claim in decision 7 with the actual `class EventEnvelope` implementation.** Decision 7 in `007-AT-ADEC-architecture-decisions.md` asserts `Data.define` is used; the file uses a plain class with `freeze`. Either migrate to `Data.define` (simpler, more idiomatic) or amend the ADR. Doc/code drift erodes the value of the ADRs.

**Nice-to-have.**

7. **Event deduplication keyed on an upstream-supplied `event_id`** — addresses threat 5 (replay inflation), which is fully-accepted residual risk in v1.
8. **Pluggable `SqliteStore`** as the v2 roadmap §2.1 lists — enables indexed queries for shops that outgrow JSON Lines.
9. **Settle the schema-version negotiation contract with gap-miner.** The data-contracts doc says "no runtime version negotiation in v1." Decide what consumers do with `schema_version` bumps; document on both sides.

---

## Brief findings

This is a small, careful, opinionated gem with a strong privacy story and an aggressive fire-and-forget posture. The architecture is sound for v1 volumes; the privacy filter is genuinely layered and adversarially tested. The most operationally significant issue is that the receiver swallows all exceptions with zero logging, leaving operators blind to ingestion failures. The biggest cross-repo data-contract problem is that `wild-gap-miner`'s operator guide invokes a `wst` CLI that does not exist in this repo — operators following the documented downstream workflow will hit `command not found`. Three doc/code drifts worth fixing in v2: the unimplemented `MemoryStore` size cap, the unimplemented opportunistic purge claimed by the threat model, and decision 7's `Data.define` claim vs the actual plain-class implementation.
