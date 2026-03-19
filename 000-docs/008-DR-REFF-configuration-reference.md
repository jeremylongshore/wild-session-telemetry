# wild-session-telemetry -- Configuration Reference

**Document type:** Developer reference
**Filed as:** `008-DR-REFF-configuration-reference.md`
**Repo:** `wild-session-telemetry`
**Status:** Active
**Last updated:** 2026-03-19
**Blueprint reference:** `001-PP-PLAN-repo-blueprint.md`

---

## 1. Purpose

This document is the authoritative reference for every configurable parameter in `wild-session-telemetry`. It covers the top-level `Configuration` object, privacy filter constants, schema validator constants, aggregation engine parameters, pattern detector parameters, and exporter wiring. If a parameter exists in the library, it is documented here.

---

## 2. Top-Level Configuration

Configuration is set through `WildSessionTelemetry.configure` and frozen after the block completes. Once frozen, any attempt to modify configuration raises `FrozenError`.

```ruby
WildSessionTelemetry.configure do |config|
  config.store = WildSessionTelemetry::Store::JsonLinesStore.new(path: '/var/data/telemetry.jsonl')
  config.retention_days = 90
  config.privacy_mode = :strict
  config.max_storage_bytes = 1_073_741_824 # 1 GB
end
```

### 2.1 Parameter Table

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `store` | `Store::Base` subclass instance or `nil` | `nil` | The storage backend. Accepts a `MemoryStore` or `JsonLinesStore` instance. When `nil`, no events are persisted. |
| `retention_days` | Integer | `90` | Number of days to retain events before they become eligible for purge. Used by `RetentionManager`. |
| `privacy_mode` | Symbol | `:strict` | Privacy enforcement mode. Currently only `:strict` is supported. Reserved for future relaxed modes. |
| `max_storage_bytes` | Integer or `nil` | `nil` | Maximum storage size in bytes for `JsonLinesStore`. When `nil`, no size-based purging occurs. Used by `RetentionManager.purge_oversized`. |

### 2.2 Configuration Freezing

After `WildSessionTelemetry.configure` yields, the configuration object is frozen via Ruby's `freeze` mechanism. This is a hard invariant -- not advisory.

**What freezing means:**

- Calling any setter (`store=`, `retention_days=`, `privacy_mode=`, `max_storage_bytes=`) raises `FrozenError`.
- The configuration object itself is immutable for the lifetime of the process.
- Changing configuration requires a process restart.

**Resetting configuration (testing only):**

```ruby
WildSessionTelemetry.reset_configuration!
```

This replaces the frozen configuration with a fresh, mutable `Configuration` instance. This method exists for test isolation. Do not call it in production code.

### 2.3 Configuration Access

Read current configuration at any time via readers:

```ruby
config = WildSessionTelemetry.configuration
config.store            # => #<WildSessionTelemetry::Store::MemoryStore ...>
config.retention_days   # => 90
config.privacy_mode     # => :strict
config.max_storage_bytes # => nil
```

Source: `lib/wild_session_telemetry/configuration.rb`

---

## 3. Privacy::Filter Constants

The privacy filter is not configurable at runtime or startup. Its behavior is controlled by hardcoded constants. This is intentional -- privacy rules must not be weakened by configuration.

Source: `lib/wild_session_telemetry/privacy/filter.rb`

### 3.1 ALLOWED_TOP_LEVEL_KEYS

```ruby
ALLOWED_TOP_LEVEL_KEYS = %i[event_type timestamp caller_id action outcome duration_ms metadata].freeze
```

Only these keys survive top-level stripping. Any key in the incoming event hash that is not in this list is removed before further processing.

| Key | Purpose |
|-----|---------|
| `event_type` | Classifies the event (`action.completed`, `gate.evaluated`, `rate_limit.checked`) |
| `timestamp` | ISO 8601 timestamp from the event source |
| `caller_id` | Service account or operator role identifier |
| `action` | The operation name |
| `outcome` | Result of the operation |
| `duration_ms` | Latency in milliseconds |
| `metadata` | Per-event-type approved fields (filtered separately) |

### 3.2 METADATA_ALLOWLISTS

Per-event-type allowlists define which metadata keys are permitted for each event type. Any metadata key not on the allowlist for the event's type is stripped.

```ruby
METADATA_ALLOWLISTS = {
  'action.completed' => %w[category operation phase denial_reason blast_radius_count confirmation_used].freeze,
  'gate.evaluated' => %w[gate_result capability_checked].freeze,
  'rate_limit.checked' => %w[rate_result current_count limit window_seconds].freeze
}.freeze
```

**`action.completed` allowed metadata:**

| Key | Type | Description |
|-----|------|-------------|
| `category` | String | Action category (e.g., `"jobs"`, `"cache"`, `"flags"`) |
| `operation` | String | Specific operation (e.g., `"retry"`, `"discard"`) |
| `phase` | String | Execution phase (e.g., `"preview"`, `"execute"`, `"confirm"`) |
| `denial_reason` | String | Why the action was denied (e.g., `"gate_denied"`, `"rate_limited"`) |
| `blast_radius_count` | Integer | Number of resources affected |
| `confirmation_used` | Boolean | Whether two-phase confirmation was required |

**`gate.evaluated` allowed metadata:**

| Key | Type | Description |
|-----|------|-------------|
| `gate_result` | String | Gate evaluation outcome (e.g., `"approved"`, `"denied"`) |
| `capability_checked` | String | Capability evaluated (e.g., `"admin.jobs.retry"`) |

**`rate_limit.checked` allowed metadata:**

| Key | Type | Description |
|-----|------|-------------|
| `rate_result` | String | Rate check outcome (e.g., `"allowed"`, `"rate_limited"`) |
| `current_count` | Integer | Current invocation count within the window |
| `limit` | Integer | Maximum allowed invocations |
| `window_seconds` | Integer | Rate limit window duration in seconds |

### 3.3 FORBIDDEN_FIELD_NAMES

These field names are stripped from metadata regardless of event type, even if they happen to appear on an allowlist. This is a safety net against PII and sensitive data leaking through metadata.

```ruby
FORBIDDEN_FIELD_NAMES = %w[
  params parameters arguments args input request_body
  before_state after_state before after snapshot state_before state_after
  nonce confirmation_nonce token confirmation_token
  stack_trace stacktrace backtrace trace error_trace
  jid redis_id execution_id internal_id adapter_id backend_id
].freeze
```

| Category | Fields | Rationale |
|----------|--------|-----------|
| Raw parameters | `params`, `parameters`, `arguments`, `args`, `input`, `request_body` | May contain application-specific data or user input |
| State snapshots | `before_state`, `after_state`, `before`, `after`, `snapshot`, `state_before`, `state_after` | May contain application data or business logic |
| Nonces/tokens | `nonce`, `confirmation_nonce`, `token`, `confirmation_token` | Cryptographic tokens that create correlation vectors |
| Stack traces | `stack_trace`, `stacktrace`, `backtrace`, `trace`, `error_trace` | Reveal internal application structure |
| Adapter IDs | `jid`, `redis_id`, `execution_id`, `internal_id`, `adapter_id`, `backend_id` | Backend-specific identifiers that enable cross-system correlation |

### 3.4 ALLOWED_VALUE_TYPES

Metadata values are type-checked. Only values matching these types survive sanitization. Arrays, Hashes, and other complex types are stripped.

```ruby
ALLOWED_VALUE_TYPES = [String, Integer, Float, TrueClass, FalseClass, NilClass].freeze
```

| Type | Example |
|------|---------|
| `String` | `"jobs"` |
| `Integer` | `42` |
| `Float` | `38.7` |
| `TrueClass` | `true` |
| `FalseClass` | `false` |
| `NilClass` | `nil` |

---

## 4. Schema::Validator Constants

The schema validator enforces structural correctness of incoming events. Its behavior is controlled by constants, not configuration.

Source: `lib/wild_session_telemetry/schema/validator.rb`

### 4.1 VALID_EVENT_TYPES

```ruby
VALID_EVENT_TYPES = %w[action.completed gate.evaluated rate_limit.checked].freeze
```

Events with an `event_type` not in this list are rejected by the validator.

### 4.2 VALID_OUTCOMES

```ruby
VALID_OUTCOMES = %w[success denied error preview rate_limited].freeze
```

Events with an `outcome` not in this list are rejected by the validator.

### 4.3 REQUIRED_FIELDS

```ruby
REQUIRED_FIELDS = %i[event_type timestamp caller_id action outcome].freeze
```

Events missing any of these fields (or with empty string values for them) are rejected. Note that `duration_ms` and `metadata` are not in the required fields list -- they are validated if present but not required for acceptance.

### 4.4 ISO8601_PATTERN

```ruby
ISO8601_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
```

Timestamps must match this pattern. The pattern requires year-month-day and hour-minute-second but is flexible on fractional seconds and timezone suffix.

---

## 5. Aggregation::Engine Parameters

The aggregation engine computes summaries, utilization, distributions, and latency statistics from stored events.

Source: `lib/wild_session_telemetry/aggregation/engine.rb`

### 5.1 Constructor Parameters

```ruby
engine = WildSessionTelemetry::Aggregation::Engine.new(min_population: 5)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `min_population` | Integer | `5` (`DEFAULT_MIN_POPULATION`) | Minimum number of events in a bucket before aggregations are emitted. Buckets with fewer events are suppressed. This prevents small-population aggregations from leaking individual usage patterns. |

### 5.2 Method Parameters

| Method | Additional Parameters | Description |
|--------|----------------------|-------------|
| `session_summaries(events, window_seconds:)` | `window_seconds` (default: `3600`) | Groups events by caller and time window, then builds per-window summaries. The `window_seconds` parameter controls the window size in seconds. |
| `tool_utilization(events)` | None | Groups events by action and computes invocation count, unique callers, success rate, and average duration. |
| `outcome_distributions(events)` | None | Groups events by action and computes per-outcome counts and percentages. |
| `latency_stats(events)` | None | Groups events by action and computes p50, p95, p99, min, max, and avg latency. Events with `nil` duration_ms are excluded. |

All four methods apply the `min_population` threshold. Buckets with fewer events than `min_population` are silently dropped from the result.

---

## 6. Aggregation::PatternDetector Parameters

The pattern detector identifies recurring action sequences and failure cascades across sessions.

Source: `lib/wild_session_telemetry/aggregation/pattern_detector.rb`

### 6.1 Constructor Parameters

```ruby
detector = WildSessionTelemetry::Aggregation::PatternDetector.new(
  min_sequence_length: 2,
  min_occurrence_count: 3,
  session_gap_seconds: 300
)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `min_sequence_length` | Integer | `2` | Minimum number of consecutive actions to consider as a sequence. Sequences shorter than this are ignored. |
| `min_occurrence_count` | Integer | `3` | Minimum number of times a sequence must appear across sessions before it is reported as a pattern. |
| `session_gap_seconds` | Integer | `300` (5 minutes) | Maximum gap in seconds between consecutive events within the same caller before a new session boundary is inferred. Events more than this many seconds apart are treated as separate sessions. |

### 6.2 Method Reference

| Method | Input | Output | Description |
|--------|-------|--------|-------------|
| `detect_sequences(events)` | Array of event envelopes | Array of pattern hashes | Groups events into per-caller sessions (split by `session_gap_seconds`), extracts all subsequences of length >= `min_sequence_length`, and returns those with occurrence count >= `min_occurrence_count`. Pattern type: `"sequential"`. |
| `detect_failure_cascades(events)` | Array of event envelopes | Array of pattern hashes | Same as `detect_sequences`, but pre-filters to only `error` and `denied` outcome events. Pattern type: `"failure_cascade"`. |

### 6.3 Pattern Output Format

Each detected pattern is a hash:

```ruby
{
  sequence: ["inspect_job", "retry_job", "inspect_job"],
  occurrence_count: 34,
  unique_callers: 3,
  pattern_type: "sequential"  # or "failure_cascade"
}
```

---

## 7. Export::Exporter Parameters

The exporter wires together the store, aggregation engine, and pattern detector to produce JSON Lines export output.

Source: `lib/wild_session_telemetry/export/exporter.rb`

### 7.1 Constructor Parameters

```ruby
exporter = WildSessionTelemetry::Export::Exporter.new(
  store: store,
  record_builder: nil,     # defaults to RecordBuilder.new
  aggregator: nil,         # optional Engine instance
  pattern_detector: nil    # optional PatternDetector instance
)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `store` | `Store::Base` subclass instance | Required | The store to query events from. |
| `record_builder` | `Export::RecordBuilder` instance or `nil` | `RecordBuilder.new` | Builds typed export records (event, session_summary, tool_utilization, etc.). Override only for custom record formats. |
| `aggregator` | `Aggregation::Engine` instance or `nil` | `nil` | When provided, the exporter runs all four aggregation methods and includes their output in the export. When `nil`, no aggregation records are produced. |
| `pattern_detector` | `Aggregation::PatternDetector` instance or `nil` | `nil` | When provided, the exporter runs sequence detection and failure cascade detection and includes pattern records in the export. When `nil`, no pattern records are produced. |

### 7.2 Export Method Parameters

```ruby
lines = exporter.export(
  since: '2026-03-12T00:00:00.000Z',
  before: '2026-03-19T15:00:00.000Z',
  event_type: 'action.completed',
  caller_id: 'service-account-ops'
)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `since` | String (ISO 8601) or `nil` | `nil` | Include events with timestamp >= this value. When `nil`, no lower bound. |
| `before` | String (ISO 8601) or `nil` | `nil` | Include events with timestamp < this value. When `nil`, no upper bound. |
| `event_type` | String or `nil` | `nil` | Filter to a specific event type (e.g., `"action.completed"`). When `nil`, all event types are included. |
| `caller_id` | String or `nil` | `nil` | Filter to a specific caller. When `nil`, all callers are included. |

The `export` method returns an array of JSON strings. The first element is the export header. Subsequent elements are event records, aggregation records, and pattern records.

---

## 8. Store::RetentionManager Parameters

The retention manager handles time-based and size-based purging of stored events.

Source: `lib/wild_session_telemetry/store/retention_manager.rb`

### 8.1 Constructor Parameters

```ruby
manager = WildSessionTelemetry::Store::RetentionManager.new(
  store: store,
  retention_days: 90,
  max_size_bytes: nil
)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `store` | `Store::Base` subclass instance | Required | The store to manage. Purge operations only work with `JsonLinesStore`. |
| `retention_days` | Integer | `90` | Events older than this many days (based on `received_at`) are purged by `purge_expired`. |
| `max_size_bytes` | Integer or `nil` | `nil` | Maximum file size in bytes. When set, `purge_oversized` removes the oldest events until the file is within this limit. When `nil`, size-based purging is disabled. |

### 8.2 Method Reference

| Method | Returns | Description |
|--------|---------|-------------|
| `purge_expired` | Integer | Removes events with `received_at` older than the retention window. Returns the number of events removed. Only operates on `JsonLinesStore`. Returns `0` for `MemoryStore`. |
| `purge_oversized` | Integer | Removes oldest events until file size is within `max_size_bytes`. Returns the number of events removed. Only operates when `max_size_bytes` is set and the store is `JsonLinesStore`. |
| `purge_all` | Integer | Runs `purge_expired` then `purge_oversized`. Returns total events removed. |

---

## 9. Store::StorageMonitor Parameters

The storage monitor provides health checks and statistics for a store.

Source: `lib/wild_session_telemetry/store/storage_monitor.rb`

### 9.1 Constructor Parameters

```ruby
monitor = WildSessionTelemetry::Store::StorageMonitor.new(store: store)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `store` | `Store::Base` subclass instance | Required | The store to monitor. |

### 9.2 Method Reference

| Method | Returns | Description |
|--------|---------|-------------|
| `stats` | Hash | Returns `{ event_count:, size_bytes:, oldest_event:, newest_event:, store_type: }`. `size_bytes` is `nil` for `MemoryStore`. Timestamps reflect `received_at` values. |
| `healthy?` | Boolean | Returns `true` if the store responds to `count` without error. Returns `false` if any exception occurs. |

---

## 10. Schema::EventEnvelope Parameters

The event envelope is the immutable record stored for each validated event.

Source: `lib/wild_session_telemetry/schema/event_envelope.rb`

### 10.1 Constructor Parameters

```ruby
envelope = WildSessionTelemetry::Schema::EventEnvelope.new(
  event_type: 'action.completed',
  timestamp: '2026-03-19T14:30:00.000Z',
  caller_id: 'service-account-ops',
  action: 'retry_job',
  outcome: 'success',
  duration_ms: 42.5,
  metadata: { category: 'jobs' },
  received_at: nil,        # auto-generated if nil
  schema_version: '1.0'    # default
)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `event_type` | String | Required | One of `VALID_EVENT_TYPES` |
| `timestamp` | String (ISO 8601) | Required | When the event occurred at the source |
| `caller_id` | String | Required | Service account or operator role identifier |
| `action` | String | Required | The operation name |
| `outcome` | String | Required | One of `VALID_OUTCOMES` |
| `duration_ms` | Numeric or `nil` | `nil` | Operation latency in milliseconds |
| `metadata` | Hash or `nil` | `{}` (frozen) | Per-event-type approved fields. Frozen on assignment. |
| `received_at` | String (ISO 8601) or `nil` | `Time.now.utc.iso8601(3)` | Auto-generated ingestion timestamp when not provided |
| `schema_version` | String | `'1.0'` | Schema version tag stored with the event |

The envelope is frozen on construction via `freeze`. All attributes are read-only.

### 10.2 Factory Method

```ruby
envelope = WildSessionTelemetry::Schema::EventEnvelope.from_raw(hash)
```

Creates an envelope from a symbol- or string-keyed hash. Keys are normalized to symbols. `received_at` and `schema_version` use their defaults.

---

## 11. Collector::EventReceiver Parameters

The event receiver is the ingestion boundary -- the `receive(event)` method that upstream emitters call.

Source: `lib/wild_session_telemetry/collector/event_receiver.rb`

### 11.1 Constructor Parameters

```ruby
receiver = WildSessionTelemetry::Collector::EventReceiver.new(
  store: store,
  validator: nil,    # defaults to Schema::Validator.new
  filter: nil        # defaults to Privacy::Filter.new
)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `store` | `Store::Base` subclass instance | Required | Where validated events are stored. |
| `validator` | `Schema::Validator` instance or `nil` | `Schema::Validator.new` | Validates event structure. Override for testing with custom validation. |
| `filter` | `Privacy::Filter` instance or `nil` | `Privacy::Filter.new` | Applies privacy filtering (top-level stripping, metadata allowlisting, forbidden field removal, value type sanitization). Override for testing only. |

### 11.2 Receive Method

```ruby
envelope = receiver.receive(event_hash)
```

- Returns the stored `EventEnvelope` on success.
- Returns `nil` on validation failure or any exception (fire-and-forget semantics).
- Never raises -- all exceptions are rescued and swallowed.

---

## 12. Error Classes

Source: `lib/wild_session_telemetry/errors.rb`

| Class | Parent | Usage |
|-------|--------|-------|
| `WildSessionTelemetry::Error` | `StandardError` | Base error class for the library |
| `WildSessionTelemetry::ValidationError` | `Error` | Schema validation failures |
| `WildSessionTelemetry::SchemaError` | `Error` | Schema definition problems |
| `WildSessionTelemetry::ConfigurationError` | `Error` | Configuration-related errors |
| `WildSessionTelemetry::StorageError` | `Error` | Storage backend errors |

---

## 13. Version

Source: `lib/wild_session_telemetry/version.rb`

```ruby
WildSessionTelemetry::VERSION = '0.1.0'
```
