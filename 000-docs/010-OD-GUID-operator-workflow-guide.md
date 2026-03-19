# wild-session-telemetry -- Operator Workflow Guide

**Document type:** Operator documentation
**Filed as:** `010-OD-GUID-operator-workflow-guide.md`
**Repo:** `wild-session-telemetry`
**Status:** Active
**Last updated:** 2026-03-19
**Blueprint reference:** `001-PP-PLAN-repo-blueprint.md`

---

## 1. Purpose

This guide covers day-to-day operator workflows for `wild-session-telemetry`. It assumes the library is already deployed (see `009-OD-OPNS-operator-deployment-guide.md`). Topics include health checks, querying stored events, running exports, using aggregations, detecting patterns, managing retention, and troubleshooting.

---

## 2. Checking Telemetry Health

### 2.1 Quick Health Check

```ruby
monitor = WildSessionTelemetry::Store::StorageMonitor.new(store: store)

monitor.healthy?
# => true
```

`healthy?` returns `true` if the store responds to `count` without raising. It returns `false` if any exception occurs (file missing, permissions error, corrupted data).

### 2.2 Detailed Statistics

```ruby
stats = monitor.stats
```

Returns a hash with these keys:

| Key | Type | Description |
|-----|------|-------------|
| `event_count` | Integer | Total number of events in the store |
| `size_bytes` | Integer or `nil` | File size in bytes (`JsonLinesStore` only; `nil` for `MemoryStore`) |
| `oldest_event` | String (ISO 8601) or `nil` | `received_at` timestamp of the oldest event |
| `newest_event` | String (ISO 8601) or `nil` | `received_at` timestamp of the most recent event |
| `store_type` | String | Fully qualified class name of the store |

**Example output:**

```ruby
{
  event_count: 4823,
  size_bytes: 1_247_392,
  oldest_event: "2026-01-15T08:23:14.221Z",
  newest_event: "2026-03-19T14:30:00.123Z",
  store_type: "WildSessionTelemetry::Store::JsonLinesStore"
}
```

### 2.3 What to Check

| Check | Healthy | Investigate |
|-------|---------|-------------|
| `healthy?` | `true` | `false` -- store is unreachable or corrupted |
| `event_count` | Growing over time | Static for extended periods -- events may not be flowing |
| `newest_event` | Recent timestamp (within hours) | Stale timestamp -- ingestion may be disconnected |
| `size_bytes` | Below `max_storage_bytes` | Approaching limit -- run retention purge |

---

## 3. Querying Stored Events

The store's `query` method retrieves events with optional filters. All filters are optional; omitting a filter means no constraint on that dimension.

### 3.1 Query Interface

```ruby
events = store.query(event_type: nil, since: nil, before: nil)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `event_type` | String or `nil` | Filter by event type. Example: `"action.completed"` |
| `since` | String (ISO 8601) or `nil` | Include events with timestamp >= this value |
| `before` | String (ISO 8601) or `nil` | Include events with timestamp < this value |

### 3.2 Examples

**All events from the last 24 hours:**

```ruby
since = (Time.now.utc - 86_400).iso8601(3)
events = store.query(since: since)
puts "#{events.size} events in the last 24 hours"
```

**Only gate evaluation events:**

```ruby
events = store.query(event_type: 'gate.evaluated')
```

**Events in a specific time window:**

```ruby
events = store.query(
  since: '2026-03-18T00:00:00.000Z',
  before: '2026-03-19T00:00:00.000Z'
)
```

**Combining filters:**

```ruby
events = store.query(
  event_type: 'action.completed',
  since: '2026-03-18T00:00:00.000Z',
  before: '2026-03-19T00:00:00.000Z'
)
```

### 3.3 Other Store Methods

| Method | Description |
|--------|-------------|
| `store.count` | Total number of events in the store |
| `store.recent(limit: 50)` | Most recent N events, newest first |
| `store.find(timestamp:, event_type:)` | Find a specific event by timestamp and event type |

---

## 4. Running Exports

The exporter produces JSON Lines output suitable for downstream consumers (e.g., `wild-gap-miner`).

### 4.1 Basic Export

```ruby
exporter = WildSessionTelemetry::Export::Exporter.new(store: store)

lines = exporter.export
```

Without filters, this exports all events in the store. Each element of `lines` is a JSON string. The first element is the export header.

### 4.2 Filtered Export

```ruby
lines = exporter.export(
  since: '2026-03-12T00:00:00.000Z',
  before: '2026-03-19T15:00:00.000Z',
  event_type: 'action.completed',
  caller_id: 'service-account-ops'
)
```

| Parameter | Effect |
|-----------|--------|
| `since` | Only events with timestamp >= this value |
| `before` | Only events with timestamp < this value |
| `event_type` | Only events of this type |
| `caller_id` | Only events from this caller |

All parameters are optional and can be combined.

### 4.3 Export with Aggregations and Patterns

To include aggregation records (session summaries, tool utilization, outcome distributions, latency stats) and pattern records, provide an aggregator and pattern detector:

```ruby
exporter = WildSessionTelemetry::Export::Exporter.new(
  store: store,
  aggregator: WildSessionTelemetry::Aggregation::Engine.new(min_population: 5),
  pattern_detector: WildSessionTelemetry::Aggregation::PatternDetector.new(
    min_sequence_length: 2,
    min_occurrence_count: 3,
    session_gap_seconds: 300
  )
)

lines = exporter.export(
  since: '2026-03-12T00:00:00.000Z',
  before: '2026-03-19T15:00:00.000Z'
)
```

The export header's `record_counts` field reflects how many records of each type are included.

### 4.4 Writing Export to File

```ruby
File.open('/var/data/exports/telemetry-export-2026-03-19.jsonl', 'w') do |f|
  lines.each { |line| f.puts(line) }
end
```

### 4.5 Export Output Structure

The first line is always the header:

```json
{
  "export_type": "session_telemetry",
  "schema_version": "1.0.0",
  "exported_at": "2026-03-19T15:00:00.000Z",
  "time_range": { "start": "2026-03-12T00:00:00.000Z", "end": "2026-03-19T15:00:00.000Z" },
  "record_counts": { "events": 1523, "session_summary": 47, "tool_utilization": 12 }
}
```

Subsequent lines are typed records identified by their `record_type` field: `"event"`, `"session_summary"`, `"tool_utilization"`, `"outcome_distribution"`, `"latency_stats"`, or `"pattern"`.

---

## 5. Using Aggregations

The aggregation engine computes summaries from a set of events. Aggregations are computed on demand -- they are not pre-computed or cached.

### 5.1 Creating an Engine

```ruby
engine = WildSessionTelemetry::Aggregation::Engine.new(min_population: 5)
```

The `min_population` parameter controls the privacy threshold. Buckets with fewer events than this value are suppressed from output. Default is `5`.

### 5.2 Session Summaries

Groups events by caller and time window, then summarizes each group.

```ruby
events = store.query(since: '2026-03-18T00:00:00.000Z')
summaries = engine.session_summaries(events, window_seconds: 3600)
```

Each summary hash contains:

| Key | Type | Description |
|-----|------|-------------|
| `caller_id` | String | The caller whose session this summarizes |
| `window_start` | String (ISO 8601) | Start of the time window |
| `window_end` | String (ISO 8601) | End of the time window |
| `event_count` | Integer | Number of events in the window |
| `distinct_actions` | Array of String | Unique action names, sorted |
| `outcome_breakdown` | Hash | Outcome counts (e.g., `{ "success" => 18, "denied" => 2 }`) |
| `total_duration_ms` | Numeric | Sum of `duration_ms` for all events in the window |

The `window_seconds` parameter defaults to `3600` (1 hour). Use `86400` for daily windows or `604800` for weekly.

### 5.3 Tool Utilization

Computes per-action usage statistics.

```ruby
utilization = engine.tool_utilization(events)
```

Each record contains:

| Key | Type | Description |
|-----|------|-------------|
| `action` | String | The action name |
| `invocation_count` | Integer | Total invocations |
| `unique_callers` | Integer | Number of distinct callers |
| `success_rate` | Float | Proportion of successful outcomes (0.0 to 1.0) |
| `avg_duration_ms` | Float or `nil` | Average latency; `nil` if no events have `duration_ms` |

### 5.4 Outcome Distributions

Computes per-action outcome breakdowns.

```ruby
distributions = engine.outcome_distributions(events)
```

Each record contains:

| Key | Type | Description |
|-----|------|-------------|
| `action` | String | The action name |
| `total_count` | Integer | Total events for this action |
| `outcomes` | Hash | Per-outcome `{ count:, percentage: }` |

Example:

```ruby
{
  action: "retry_job",
  total_count: 156,
  outcomes: {
    "success" => { count: 144, percentage: 0.923 },
    "denied" => { count: 5, percentage: 0.032 },
    "error" => { count: 3, percentage: 0.019 }
  }
}
```

### 5.5 Latency Statistics

Computes percentile latency metrics per action.

```ruby
latency = engine.latency_stats(events)
```

Each record contains:

| Key | Type | Description |
|-----|------|-------------|
| `action` | String | The action name |
| `sample_count` | Integer | Number of events with non-nil `duration_ms` |
| `p50` | Numeric | 50th percentile latency |
| `p95` | Numeric | 95th percentile latency |
| `p99` | Numeric | 99th percentile latency |
| `min` | Numeric | Minimum latency |
| `max` | Numeric | Maximum latency |
| `avg` | Float | Mean latency |

Events with `nil` `duration_ms` are excluded from latency calculations.

---

## 6. Pattern Detection

The pattern detector identifies recurring sequences of actions and failure cascades.

### 6.1 Creating a Detector

```ruby
detector = WildSessionTelemetry::Aggregation::PatternDetector.new(
  min_sequence_length: 2,
  min_occurrence_count: 3,
  session_gap_seconds: 300
)
```

| Parameter | Default | Effect |
|-----------|---------|--------|
| `min_sequence_length` | `2` | Ignore sequences shorter than this |
| `min_occurrence_count` | `3` | Only report patterns that appear at least this many times |
| `session_gap_seconds` | `300` | Events more than 5 minutes apart (per caller) start a new session |

### 6.2 Detecting Action Sequences

```ruby
events = store.query(since: '2026-03-12T00:00:00.000Z')
patterns = detector.detect_sequences(events)
```

Returns an array of pattern hashes, sorted by occurrence count (most frequent first):

```ruby
{
  sequence: ["inspect_job", "retry_job", "inspect_job"],
  occurrence_count: 34,
  unique_callers: 3,
  pattern_type: "sequential"
}
```

This means 3 different callers performed the sequence inspect -> retry -> inspect a total of 34 times.

### 6.3 Detecting Failure Cascades

```ruby
cascades = detector.detect_failure_cascades(events)
```

Same interface as `detect_sequences`, but pre-filters events to only those with `outcome` of `"error"` or `"denied"`. Pattern type is `"failure_cascade"`.

This is useful for identifying repeated failure patterns -- for example, a sequence of denied gate checks followed by denied action attempts.

### 6.4 Interpreting Patterns

| Pattern | Interpretation | Action |
|---------|---------------|--------|
| High-frequency sequential pattern | Common workflow that operators repeat | Consider automating or combining steps |
| Failure cascade with high occurrence | Systematic access or configuration issue | Investigate gate rules, rate limits, or permissions |
| Single-caller pattern with high count | One operator with a repetitive workflow | May indicate a missing batch operation |
| Multi-action pattern ending in error | Workflow that consistently fails at a specific step | Investigate the failing action |

---

## 7. Retention Management

Retention is managed explicitly through the `RetentionManager`. There is no background purge process.

### 7.1 Creating a RetentionManager

```ruby
manager = WildSessionTelemetry::Store::RetentionManager.new(
  store: store,
  retention_days: 90,
  max_size_bytes: 1_073_741_824
)
```

### 7.2 Purging Expired Events

```ruby
removed = manager.purge_expired
puts "Removed #{removed} expired events"
```

Removes events whose `received_at` timestamp is older than `retention_days` days ago. Only operates on `JsonLinesStore`. Returns `0` for `MemoryStore`.

### 7.3 Purging Oversized Storage

```ruby
removed = manager.purge_oversized
puts "Removed #{removed} events to bring storage within size limit"
```

Removes the oldest events until the file size is within `max_size_bytes`. Only operates when `max_size_bytes` is set and the store is `JsonLinesStore`.

### 7.4 Running Both Purges

```ruby
removed = manager.purge_all
puts "Total removed: #{removed}"
```

Runs `purge_expired` first, then `purge_oversized`. Returns the combined count.

### 7.5 Recommended Purge Schedule

| Deployment | Frequency | Method |
|------------|-----------|--------|
| Low volume (< 100 events/day) | Weekly | `purge_all` |
| Medium volume (100-10,000 events/day) | Daily | `purge_all` |
| High volume (> 10,000 events/day) | Every 6 hours | `purge_all` |
| Before every export | On demand | `purge_all` |

### 7.6 How Purge Works

For `purge_expired`: reads the entire file line by line, parses each line's `received_at` field, retains lines where `received_at` is after the cutoff, rewrites the file with only the retained lines.

For `purge_oversized`: reads all lines, removes lines from the front (oldest first) until the total byte size is within `max_size_bytes`, rewrites the file.

Both methods rewrite the file in place. During rewrite, there is a brief window where the file is being replaced. The mutex prevents concurrent writes from the same process, but external processes reading the file may see a truncated state during rewrite.

---

## 8. Troubleshooting

### 8.1 No Events Being Stored

**Symptoms:** `store.count` returns `0` or stays static. `monitor.stats[:newest_event]` is `nil` or stale.

**Possible causes:**

| Cause | Check | Fix |
|-------|-------|-----|
| Receiver not subscribed to emitter | Verify `hook_emitter.subscribe(receiver)` was called | Add the subscription in your startup code |
| Events failing validation | All required fields must be present and valid | Check that upstream events include `event_type`, `timestamp`, `caller_id`, `action`, `outcome` |
| Invalid event_type | Must be one of: `action.completed`, `gate.evaluated`, `rate_limit.checked` | Fix the upstream emitter |
| Invalid outcome | Must be one of: `success`, `denied`, `error`, `preview`, `rate_limited` | Fix the upstream emitter |
| Invalid timestamp format | Must match ISO 8601 (`YYYY-MM-DDTHH:MM:SS...`) | Fix the upstream emitter |
| Store is nil | Configuration `store` was not set | Set `config.store` in the configure block |
| Exceptions being swallowed | `receive` rescues all `StandardError` | Check stderr/logs for exception output |

**Debugging approach:**

```ruby
# Bypass the receiver and test the pipeline steps individually:
filter = WildSessionTelemetry::Privacy::Filter.new
validator = WildSessionTelemetry::Schema::Validator.new

raw_event = { ... } # your test event

filtered = filter.filter(raw_event)
puts "Filtered: #{filtered.inspect}"

valid, errors = validator.validate(filtered)
puts "Valid: #{valid}"
puts "Errors: #{errors.inspect}" unless valid
```

### 8.2 Events Being Stripped of Metadata

**Symptoms:** Events are stored but `metadata` is empty or missing expected keys.

**Possible causes:**

| Cause | Check | Fix |
|-------|-------|-----|
| Metadata key not on allowlist | Check `Privacy::Filter::METADATA_ALLOWLISTS` for the event's type | Only allowlisted keys are stored; add keys to the allowlist in code if they are approved |
| Metadata key is on the forbidden list | Check `Privacy::Filter::FORBIDDEN_FIELD_NAMES` | Forbidden names are always stripped regardless of allowlist; rename the field upstream |
| Metadata value has disallowed type | Check `Privacy::Filter::ALLOWED_VALUE_TYPES` | Only String, Integer, Float, Boolean, and nil are allowed; do not send Arrays or Hashes as metadata values |
| Keys sent as strings but allowlist uses different format | Filter normalizes keys to strings for comparison | This should work automatically; verify key spelling |

### 8.3 File Permission Errors

**Symptoms:** Events appear to be ingested (no errors) but `store.count` returns `0`. Or `JsonLinesStore` raises errors on construction.

**Check:**

```bash
ls -la /var/data/wild-telemetry/
# Verify the application user has write access
```

**Fix:**

```bash
chown appuser:appgroup /var/data/wild-telemetry
chmod 750 /var/data/wild-telemetry
```

### 8.4 Storage Growing Beyond Expected Size

**Symptoms:** `monitor.stats[:size_bytes]` exceeds `max_storage_bytes`.

**Cause:** `RetentionManager.purge_oversized` has not been called. Size-based retention does not happen automatically.

**Fix:** Run `manager.purge_all` or set up a periodic purge schedule (see Section 7.5).

### 8.5 Export Returns Empty Results

**Symptoms:** `exporter.export(...)` returns only the header line with `record_counts.events: 0`.

**Possible causes:**

| Cause | Fix |
|-------|-----|
| `since`/`before` window contains no events | Widen the time range or check `store.query` with the same filters |
| `event_type` filter does not match any stored events | Verify the event type string exactly matches (e.g., `"action.completed"` not `"action_completed"`) |
| `caller_id` filter does not match | Verify the caller_id string matches what was stored |
| Store is empty | Check `store.count`; verify ingestion is working |

### 8.6 Aggregations Return Empty Arrays

**Symptoms:** `engine.session_summaries(events)` or other aggregation methods return `[]`.

**Possible causes:**

| Cause | Fix |
|-------|-----|
| Too few events in each bucket | Each bucket needs at least `min_population` events (default: 5). Lower the threshold for testing: `Engine.new(min_population: 1)` |
| Events span too many actions/callers | Events are grouped by action or caller; if each group has fewer than `min_population`, all are suppressed | Collect more data or lower the threshold |
| No events passed to the method | Verify the events array is not empty before calling aggregation methods |

### 8.7 Pattern Detection Finds No Patterns

**Symptoms:** `detector.detect_sequences(events)` returns `[]`.

**Possible causes:**

| Cause | Fix |
|-------|-----|
| Too few occurrences | Each sequence must appear at least `min_occurrence_count` times (default: 3). Lower for testing. |
| Sessions too short | Each session needs at least `min_sequence_length` events (default: 2). Single-event sessions produce no sequences. |
| Large time gaps between events | Events more than `session_gap_seconds` apart (default: 300) are split into separate sessions. Increase for sparse event streams. |
| Only one caller | Patterns are detected per-caller. A single caller with few events may not produce enough sessions. |

### 8.8 Configuration Frozen Error

**Symptoms:** `FrozenError: can't modify frozen WildSessionTelemetry::Configuration`

**Cause:** Attempting to modify configuration after `WildSessionTelemetry.configure` has been called.

**Fix:** Configuration is immutable after the configure block. To change settings, restart the process. For test environments, call `WildSessionTelemetry.reset_configuration!` before reconfiguring.
