# wild-session-telemetry -- Operator Deployment Guide

**Document type:** Operator documentation
**Filed as:** `009-OD-OPNS-operator-deployment-guide.md`
**Repo:** `wild-session-telemetry`
**Status:** Active
**Last updated:** 2026-03-19
**Blueprint reference:** `001-PP-PLAN-repo-blueprint.md`

---

## 1. Purpose

This guide covers everything an operator needs to deploy `wild-session-telemetry` in a Ruby application. It starts with prerequisites, walks through installation and configuration, and ends with production deployment considerations.

---

## 2. Prerequisites

| Requirement | Minimum | Notes |
|-------------|---------|-------|
| Ruby | 3.2+ | `Data.define` and other 3.2 features are used throughout |
| Bundler | Any recent version | Standard gem dependency management |
| Filesystem access | Write access to one directory | Required only if using `JsonLinesStore` |

The library is a pure Ruby gem with no native extensions. No database, Redis, or external service is required.

---

## 3. Installation

Add the gem to your `Gemfile`:

```ruby
gem 'wild_session_telemetry'
```

Install:

```bash
bundle install
```

Require in your application:

```ruby
require 'wild_session_telemetry'
```

---

## 4. Basic Configuration

Configuration happens once at application startup. After the `configure` block completes, the configuration is frozen and cannot be modified.

### 4.1 Minimal Configuration (Testing / Development)

```ruby
store = WildSessionTelemetry::Store::MemoryStore.new

WildSessionTelemetry.configure do |config|
  config.store = store
end
```

`MemoryStore` holds events in an in-process array. Events are lost when the process exits. This is appropriate for test suites and development environments where persistence is not required.

### 4.2 Production Configuration (JsonLinesStore)

```ruby
store = WildSessionTelemetry::Store::JsonLinesStore.new(
  path: '/var/data/wild-telemetry/telemetry.jsonl'
)

WildSessionTelemetry.configure do |config|
  config.store = store
  config.retention_days = 90
  config.max_storage_bytes = 1_073_741_824  # 1 GB
end
```

`JsonLinesStore` persists events to a single `.jsonl` file. Each event is one JSON object per line. The directory is created automatically if it does not exist (the process must have write permission to the parent directory).

### 4.3 Configuration Parameters

| Parameter | Default | Recommended Production Value | Purpose |
|-----------|---------|------------------------------|---------|
| `store` | `nil` | `JsonLinesStore` instance | Where events are stored |
| `retention_days` | `90` | `90` (adjust based on export frequency) | How long events are retained before purge eligibility |
| `privacy_mode` | `:strict` | `:strict` (the only supported mode) | Privacy enforcement level |
| `max_storage_bytes` | `nil` | Set based on available disk (e.g., `1_073_741_824` for 1 GB) | Upper bound on telemetry file size |

---

## 5. Creating the Ingestion Pipeline

The ingestion pipeline has three components: a store, a privacy filter, a schema validator, and an event receiver that wires them together.

### 5.1 Default Wiring

```ruby
store = WildSessionTelemetry::Store::JsonLinesStore.new(
  path: '/var/data/wild-telemetry/telemetry.jsonl'
)

receiver = WildSessionTelemetry::Collector::EventReceiver.new(store: store)
```

The `EventReceiver` creates a default `Privacy::Filter` and `Schema::Validator` internally. You do not need to instantiate them separately unless you need to override them for testing.

### 5.2 Attaching to a HookEmitter

The receiver implements the `receive(event)` subscriber interface expected by `wild-admin-tools-mcp`'s `HookEmitter`:

```ruby
# In your application startup, after configuring the HookEmitter:
hook_emitter.subscribe(receiver)
```

Once subscribed, the receiver processes every event the emitter publishes. Events flow through this pipeline:

1. `Privacy::Filter.filter` -- strips unknown top-level keys, enforces metadata allowlists, removes forbidden fields, sanitizes value types
2. `Schema::Validator.validate` -- checks required fields, validates event_type, outcome, timestamp format, duration_ms type, metadata type
3. `Schema::EventEnvelope.from_raw` -- creates an immutable envelope with `received_at` timestamp
4. `Store#append` -- persists the envelope

If any step fails, the receiver returns `nil` and does not propagate the error upstream. This is the fire-and-forget guarantee.

---

## 6. Verifying the Setup

After wiring, verify that events flow through the pipeline.

### 6.1 Send a Test Event

```ruby
test_event = {
  event_type: 'action.completed',
  timestamp: Time.now.utc.iso8601(3),
  caller_id: 'setup-verification',
  action: 'test_action',
  outcome: 'success',
  duration_ms: 1.0,
  metadata: { category: 'test', operation: 'verify' }
}

result = receiver.receive(test_event)
```

If `result` is an `EventEnvelope` instance, ingestion is working. If `result` is `nil`, the event was rejected -- check that all required fields are present and values are valid.

### 6.2 Check the Store

```ruby
puts store.count
# => 1

recent = store.recent(limit: 1)
puts recent.first.action
# => "test_action"
```

### 6.3 Check Storage Health

```ruby
monitor = WildSessionTelemetry::Store::StorageMonitor.new(store: store)

puts monitor.healthy?
# => true

puts monitor.stats
# => { event_count: 1, size_bytes: 287, oldest_event: "2026-03-19T14:30:00.123Z",
#      newest_event: "2026-03-19T14:30:00.123Z",
#      store_type: "WildSessionTelemetry::Store::JsonLinesStore" }
```

---

## 7. Production Deployment Considerations

### 7.1 File Path Selection

Choose a path for `JsonLinesStore` that meets these requirements:

| Requirement | Rationale |
|-------------|-----------|
| On a persistent filesystem | Ephemeral filesystems (tmpfs, container scratch space) lose data on restart |
| Dedicated directory | Avoids conflicts with other applications writing to the same directory |
| Backed by reliable storage | SSD or networked storage with replication for durability |
| Sufficient free space | At least 2x `max_storage_bytes` to allow for purge rewriting |

Example paths:

```
/var/data/wild-telemetry/telemetry.jsonl       # Linux, dedicated data directory
/opt/app/data/telemetry/telemetry.jsonl        # Application-scoped data directory
```

### 7.2 File Permissions

The application process must have:

- **Write** access to the telemetry file path
- **Write** access to the parent directory (for file creation on first run)
- **Read** access to the telemetry file (for queries and exports)

Recommended permissions:

```bash
# Create the directory with restricted access
mkdir -p /var/data/wild-telemetry
chown appuser:appgroup /var/data/wild-telemetry
chmod 750 /var/data/wild-telemetry
```

The telemetry file is created automatically on first `append`. Do not pre-create it.

### 7.3 Retention Configuration

Retention is not automatic. You must run `RetentionManager` methods to purge expired and oversized data. This can be done:

**Option A: As a periodic task (recommended)**

```ruby
manager = WildSessionTelemetry::Store::RetentionManager.new(
  store: store,
  retention_days: WildSessionTelemetry.configuration.retention_days,
  max_size_bytes: WildSessionTelemetry.configuration.max_storage_bytes
)

# Run daily via cron, scheduled job, or application-level timer
removed = manager.purge_all
puts "Purged #{removed} expired/oversized events"
```

**Option B: Inline before exports**

```ruby
# Purge before each export to ensure exports only contain valid data
manager.purge_all
lines = exporter.export(since: since, before: before)
```

### 7.4 Disk Space Monitoring

Monitor disk usage independently of the library. The `StorageMonitor` reports `size_bytes` for `JsonLinesStore`, but external monitoring (e.g., disk usage alerts) is the operator's responsibility.

```ruby
monitor = WildSessionTelemetry::Store::StorageMonitor.new(store: store)
stats = monitor.stats

if stats[:size_bytes] && stats[:size_bytes] > warning_threshold
  # Alert operator
end
```

### 7.5 Process Restart Behavior

- **MemoryStore**: All data is lost on restart. This is expected and by design.
- **JsonLinesStore**: Data persists across restarts. The new process appends to the existing file. No migration or recovery step is needed.

Configuration must be re-applied on restart (it is not persisted). Use the same `configure` block in your application initialization.

### 7.6 Multi-Process Deployments

If your application runs multiple processes (e.g., Puma workers, Sidekiq processes), each process that needs telemetry must have its own `EventReceiver` and store.

**Shared JsonLinesStore file**: Multiple processes can append to the same file because appends are newline-delimited and the `JsonLinesStore` uses a mutex for thread safety within a single process. However, cross-process file locking is not implemented. For high-concurrency multi-process deployments, use per-process files and merge at export time.

**Per-process MemoryStore**: Each process has its own independent store. There is no cross-process data sharing.

### 7.7 Containerized Deployments

For Docker or Kubernetes deployments:

- Mount a persistent volume at the telemetry data path
- Set `max_storage_bytes` to a value within the volume's capacity
- Run retention purges as a sidecar or periodic job
- If using ephemeral containers without persistent volumes, use `MemoryStore` and accept that data is lost on container restart

---

## 8. Full Production Setup Example

```ruby
# config/initializers/telemetry.rb (Rails example)
# or in your application startup code

require 'wild_session_telemetry'

# 1. Create the store
telemetry_store = WildSessionTelemetry::Store::JsonLinesStore.new(
  path: ENV.fetch('TELEMETRY_DATA_PATH', '/var/data/wild-telemetry/telemetry.jsonl')
)

# 2. Configure the library
WildSessionTelemetry.configure do |config|
  config.store = telemetry_store
  config.retention_days = ENV.fetch('TELEMETRY_RETENTION_DAYS', 90).to_i
  config.max_storage_bytes = ENV.fetch('TELEMETRY_MAX_BYTES', 1_073_741_824).to_i
end

# 3. Create the event receiver
telemetry_receiver = WildSessionTelemetry::Collector::EventReceiver.new(
  store: telemetry_store
)

# 4. Subscribe to the hook emitter (application-specific)
# hook_emitter.subscribe(telemetry_receiver)

# 5. Set up retention management (run periodically)
TELEMETRY_RETENTION_MANAGER = WildSessionTelemetry::Store::RetentionManager.new(
  store: telemetry_store,
  retention_days: WildSessionTelemetry.configuration.retention_days,
  max_size_bytes: WildSessionTelemetry.configuration.max_storage_bytes
)

# 6. Set up the exporter (for on-demand exports)
TELEMETRY_EXPORTER = WildSessionTelemetry::Export::Exporter.new(
  store: telemetry_store,
  aggregator: WildSessionTelemetry::Aggregation::Engine.new,
  pattern_detector: WildSessionTelemetry::Aggregation::PatternDetector.new
)

# 7. Set up the storage monitor (for health checks)
TELEMETRY_MONITOR = WildSessionTelemetry::Store::StorageMonitor.new(
  store: telemetry_store
)
```
