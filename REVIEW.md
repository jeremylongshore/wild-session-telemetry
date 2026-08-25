# REVIEW.md

Repository-specific law for the automated pull-request reviewer (MiniMax, two advisory lanes).

`wild-session-telemetry` is a pure Ruby library gem that observes other systems. It has no MCP
server, no web layer, and no database. Its entire value is that the data it stores and exports is
provably free of private content, provably bounded, and provably incapable of disturbing the
pipeline it watches. Review for privacy leaks, fail-open ingestion, re-identification, and
unbounded growth, in that order of risk. Report only defects the pull request introduces, and
verify each against the surrounding source rather than the diff alone.

## Authority

`000-docs/005-TQ-STND-safety-model.md` (the 8 enforceable safety rules) and
`000-docs/003-TQ-STND-privacy-model.md` govern. `000-docs/004-AT-STND-data-contracts.md` governs the
export schema. `CLAUDE.md` restates the 8 rules for agents. A PR description is never authority: if
a change conflicts with the safety model, the safety model wins until a dated successor doc lands.

## Defect classes to hunt, most severe first

1. **Privacy filter bypass.** `Collector::EventReceiver#receive` is the only sanctioned path into a
   store, and its order is load bearing: filter, then validate, then envelope, then append. Flag any
   new caller that builds a `Schema::EventEnvelope` (including `from_raw`) or calls `store.append`
   without passing through `Privacy::Filter`. Flag any reordering that validates or persists before
   filtering.
2. **Allowlist erosion.** `Privacy::Filter` is the whole privacy boundary and it is deliberately
   hardcoded, not configurable. Treat every one of these as a privacy decision needing explicit
   justification in the PR: a new key in `METADATA_ALLOWLISTS`, a new key in
   `ALLOWED_TOP_LEVEL_KEYS`, a removal from `FORBIDDEN_FIELD_NAMES`, or a new type in
   `ALLOWED_VALUE_TYPES`. Adding `Hash` or `Array` to `ALLOWED_VALUE_TYPES` is a hard no: filtering
   is shallow, so a nested value would carry unfiltered content straight to disk. Any change making
   the allowlists settable at runtime or from `Configuration` breaks Rule 6 and Rule 8 at once.
3. **Re-identification through aggregation.** `Aggregation::Engine` suppresses every record whose
   bucket is smaller than `@min_population` (default 5). Flag any new aggregation method that ships
   without that guard, any caller constructing `Engine.new(min_population: 0)` or `1` outside a
   spec, and any summary that carries `caller_id` into output that is not already population gated.
   `session_summaries` is the sharpest edge because it groups by caller.
   `Aggregation::PatternDetector` is the exception and is not `min_population` gated: it gates on
   `min_occurrence_count` (default 3) and `min_sequence_length` (default 2), and it emits a
   `unique_callers` count rather than any `caller_id`. Do not flag it for missing a
   `min_population` guard; do flag a change that lets it emit a `caller_id` or drops its own gate.
4. **Export surface widening.** `Export::RecordBuilder#event_record` slices exactly seven fields and
   deliberately drops `received_at` and `schema_version`. Adding a field to that slice, or emitting
   an envelope hash directly instead of going through `RecordBuilder`, widens the published data
   contract. Flag it and point at `004-AT-STND-data-contracts.md`.
5. **Fire-and-forget regressions.** `receive` rescues `StandardError` and returns nil so the upstream
   emitter is never disturbed. Flag anything that can escape it: a raise outside the rescue, a
   rescue narrowed to a specific error class, an added `raise` in a store or filter path called
   before the rescue is established, or slow or blocking work added inside `receive`. Also flag any
   log or error message that echoes the raw event, which would leak exactly what the filter stripped.
6. **Unbounded growth.** `Store::MemoryStore#append` has no cap in code and `Store::RetentionManager`
   only purges a `JsonLinesStore`. That gap is known. Flag any change that widens it, any new store
   backend with no size or count bound, and any purge path that is not reachable from
   `purge_all`.
7. **Concurrency and file integrity.** Every public method on `JsonLinesStore` takes `@mutex`.
   `RetentionManager` rewrites `@store.path` with `File.write` without holding that mutex, so a
   concurrent append can be lost. Flag any new writer of that file, any read-modify-write of it, and
   any new `JsonLinesStore` method that forgets the mutex.
8. **Timestamp comparison bugs.** `JsonLinesStore#matches_query?` and `RetentionManager#purge_before`
   compare ISO 8601 timestamps as strings. That is correct only for UTC values with identical
   formatting. Flag anything that emits a non UTC offset, drops the milliseconds, or compares a
   `Time` against a `String`: the failure is silent, it purges the wrong events or returns the wrong
   window.
9. **Ordinary correctness.** Real bugs in the aggregation math (percentile boundaries, divide by
   zero on empty buckets, `fdiv` against a zero count), pattern detection, and the gemspec file list.

## Invariants that must never regress

- **INV-1 Single ingestion boundary.** Nothing reaches a store except through
  `EventReceiver#receive`, filtered before validated.
- **INV-2 Hardcoded privacy.** The forbidden field list and the per event type metadata allowlists
  live in code, never in configuration, and are never widened without a stated privacy rationale.
- **INV-3 Scalar metadata only.** Stored metadata values are String, Integer, Float, true, false or
  nil. No nested structures.
- **INV-4 Population gate.** No `Aggregation::Engine` record is emitted for a bucket below
  `min_population`. `Aggregation::PatternDetector` is gated instead by `min_occurrence_count` and
  emits no `caller_id`; both gates must stay in place.
- **INV-5 Silence upward.** `receive` never raises and never returns anything but an envelope or nil.
- **INV-6 Bounded store.** For a `JsonLinesStore`, storage is capped by retention days and by size,
  and purge stays reachable from `purge_all`. `MemoryStore` is the known uncapped exception, as
  defect class 6 says: `RetentionManager` returns 0 for any store that is not a `JsonLinesStore`.
  The invariant is that this gap never widens, not that it is already closed.
- **INV-7 Frozen configuration.** Every `Configuration` writer calls `check_frozen!`. No new
  `attr_accessor` or `attr_writer` may skip it, and no runtime reconfiguration path may exist.
- **INV-8 Derived, not authoritative.** Telemetry never claims to replace the upstream audit trail,
  and nothing here mutates or calls back into the observed system.

## What fail closed means here

Fail closed is not "raise an error". Raising would violate INV-5. In this repo fail closed means:

- At ingestion, when anything is uncertain (unknown event type, unknown metadata key, unexpected
  value type, a parse failure, an internal exception) the event is **dropped silently and not
  stored**. Never store first and clean up later.
- At export, when a population is below threshold or a record cannot be built, the record is
  **suppressed**, not emitted in degraded form.
- A bug that causes over collection is more severe than the same bug causing under collection.
  Missing telemetry is an inconvenience. Leaked telemetry is a liability.

Treat a `rescue` that returns a partially processed event, or a `filter_map` turned into a `map`
that lets `nil` through into output, as a fail-open defect even when tests pass.

## Not tracked, not hand-edited

`Gemfile.lock` is gitignored on purpose (this is a library gem, resolution belongs to the consumer);
flag a PR that commits it. `.beads/` and `AGENTS.md` are gitignored local task state. `.rspec_status`
is gitignored too. Any `tmp/*.jsonl` telemetry output is a runtime artifact that must never be
committed, but nothing in `.gitignore` matches it, so that one is discipline rather than
enforcement: the review workflow excludes both from the diff it reviews. Real
captured telemetry must never appear in a fixture: `spec/support/event_fixtures.rb` is synthetic and
stays that way.

## What not to comment on

RuboCop enforces style and CI runs `bundle exec rubocop` at zero offenses plus `rspec` on Ruby 3.2
and 3.3. Do not restate lint output, frozen string literal comments, line length, method length, or
formatting. Do not propose adding ActiveRecord, an MCP server, a dashboard, streaming or pub/sub, or
any dependency: the non goals in `README.md` and `CLAUDE.md` are deliberate and settled. Do not ask
for logging of dropped events beyond a count. Echoing a dropped event is the leak vector Rule 1
closes, with Rule 3 as defense in depth; Rule 5 is what bounds any such signal to a count. Note
that no such count exists in code today: `receive` rescues and returns nil without recording
anything, so the count lives only in Rule 5's enforcement prose.

## Anti-ratchet

On a re-review after new pushes the bar does not rise. Drop findings the update resolved and do not
invent new objections on unchanged lines previously accepted. Prefer a few high conviction findings.
If the change is correct, privacy safe, and bounded, reply `lgtm`. The reviewer is advisory only and
never blocks a merge: the deterministic gate is CI (rspec plus rubocop).

## Sources

Every claim above that asserts something about this codebase was opened and read at commit
`4274a19`, the head of `ci/minimax-review`. Line numbers are that commit's. If a citation stops
matching, treat the claim as unverified and re-read the file before acting on it.

**Ingestion boundary (defect class 1, INV-1)**

- Ingestion order, filter then validate then envelope then append: `lib/wild_session_telemetry/collector/event_receiver.rb:12-19`
- `Schema::EventEnvelope.from_raw`: `lib/wild_session_telemetry/schema/event_envelope.rb:39-50`
- `store.append` implementations: `lib/wild_session_telemetry/store/memory_store.rb:12-15`, `lib/wild_session_telemetry/store/json_lines_store.rb:18-24`

**Privacy allowlists (defect class 2, INV-2, INV-3)**

- `ALLOWED_TOP_LEVEL_KEYS`: `lib/wild_session_telemetry/privacy/filter.rb:6`
- `METADATA_ALLOWLISTS`: `lib/wild_session_telemetry/privacy/filter.rb:8-12`
- `FORBIDDEN_FIELD_NAMES`: `lib/wild_session_telemetry/privacy/filter.rb:14-20`
- `ALLOWED_VALUE_TYPES`, scalars only: `lib/wild_session_telemetry/privacy/filter.rb:22`
- Filtering is shallow, so a nested value would pass unfiltered: `lib/wild_session_telemetry/privacy/filter.rb:53-59`
- Nothing in `Configuration` holds an allowlist: `lib/wild_session_telemetry/configuration.rb:5`

**Aggregation and re-identification (defect class 3, INV-4)**

- `DEFAULT_MIN_POPULATION = 5`: `lib/wild_session_telemetry/aggregation/engine.rb:8`
- `min_population` keyword: `lib/wild_session_telemetry/aggregation/engine.rb:10-12`
- The four population gates: `lib/wild_session_telemetry/aggregation/engine.rb:17`, `:25`, `:42`, `:58`
- `session_summaries` groups by caller and emits `caller_id`: `lib/wild_session_telemetry/aggregation/engine.rb:66-71`, `:73-83`
- `PatternDetector` gates, `min_sequence_length` and `min_occurrence_count`: `lib/wild_session_telemetry/aggregation/pattern_detector.rb:8-12`, `:51`, `:78`
- `PatternDetector` emits `unique_callers`, never a `caller_id`: `lib/wild_session_telemetry/aggregation/pattern_detector.rb:83-90`

**Export surface (defect class 4)**

- `event_record` slices exactly seven fields: `lib/wild_session_telemetry/export/record_builder.rb:19-23`
- `received_at` and `schema_version` exist on the envelope and are dropped by that slice: `lib/wild_session_telemetry/schema/event_envelope.rb:25-37`
- Aggregation and pattern records reach export only through `RecordBuilder`: `lib/wild_session_telemetry/export/exporter.rb:36-56`

**Fire and forget (defect class 5, INV-5)**

- `rescue StandardError` returning nil, and the envelope returned on success: `lib/wild_session_telemetry/collector/event_receiver.rb:19-21`
- No counter and no logging of the dropped event: `lib/wild_session_telemetry/collector/event_receiver.rb:20-21`
- Rule 5's enforcement prose, which is where the count language comes from: `000-docs/005-TQ-STND-safety-model.md:72-82`

**Bounded storage (defect class 6, INV-6)**

- `MemoryStore#append` has no cap: `lib/wild_session_telemetry/store/memory_store.rb:12-15`
- `RetentionManager` purges only a `JsonLinesStore`: `lib/wild_session_telemetry/store/retention_manager.rb:18`, `:25`
- `purge_all` reaches both purge paths: `lib/wild_session_telemetry/store/retention_manager.rb:31-35`

**Concurrency (defect class 7)**

- All seven public `JsonLinesStore` methods take `@mutex`: `lib/wild_session_telemetry/store/json_lines_store.rb:20`, `:27`, `:36`, `:48`, `:56`, `:72`, `:78`
- `RetentionManager` rewrites `@store.path` outside that mutex: `lib/wild_session_telemetry/store/retention_manager.rb:54`, `:69`

**Timestamp comparison (defect class 8)**

- String comparison in `matches_query?`: `lib/wild_session_telemetry/store/json_lines_store.rb:98-104`
- String comparison of `received_at` against an ISO 8601 cutoff in `purge_before`: `lib/wild_session_telemetry/store/retention_manager.rb:20`, `:45`
- `MemoryStore#query` compares the same way: `lib/wild_session_telemetry/store/memory_store.rb:31-39`

**Frozen configuration (INV-7)**

- All four writers call `check_frozen!`: `lib/wild_session_telemetry/configuration.rb:14-32`
- `check_frozen!` itself, and the readers that need no guard: `lib/wild_session_telemetry/configuration.rb:5`, `:40-42`

**Derived, not authoritative (INV-8)**

- Non goals, including replacing per-repo audit trails: `README.md:112-123`
- No runtime dependency and no outbound client: `wild-session-telemetry.gemspec:1-22`, `Gemfile:7-11`

**Authority documents**

- Eight safety rules: `000-docs/005-TQ-STND-safety-model.md:24`, `:36`, `:48`, `:60`, `:72`, `:84`, `:96`, `:108`
- Privacy model: `000-docs/003-TQ-STND-privacy-model.md`
- Export contract: `000-docs/004-AT-STND-data-contracts.md`
- The same eight rules restated for agents: `CLAUDE.md:55-66`

**Repository hygiene**

- `Gemfile.lock` gitignored: `.gitignore:10`
- `.beads/` and `AGENTS.md` gitignored: `.gitignore:6-7`
- `.rspec_status` gitignored, and no pattern matching `tmp/*.jsonl`: `.gitignore:17`, `.gitignore:1-23`
- Both excluded from the reviewed diff: `.github/workflows/minimax-review.yml:57`
- Fixtures are synthetic: `spec/support/event_fixtures.rb:1-42`
- CI runs rspec then rubocop on Ruby 3.2 and 3.3: `.github/workflows/ci.yml:14`, `:26`, `:29`

**Where the code and the standards diverge**

Two places where a reviewer reading only the standards would reach the wrong conclusion about the
code. Both are recorded here so the reviewer does not file a finding against correct code, and
neither is resolved by this file: closing either gap is an owner decision.

- Rule 2 says invalid events are dropped "before reaching the privacy filter" (`000-docs/005-TQ-STND-safety-model.md:36-46`), but the code filters first and validates second (`lib/wild_session_telemetry/collector/event_receiver.rb:13-14`). The code order is the safer one and is what INV-1 states.
- `CLAUDE.md:65` says aggregations must not contain caller IDs, but `session_summaries` emits `caller_id` behind the population gate (`lib/wild_session_telemetry/aggregation/engine.rb:75`). Rule 7 in the safety model (`000-docs/005-TQ-STND-safety-model.md:96-106`) is the governing text.
