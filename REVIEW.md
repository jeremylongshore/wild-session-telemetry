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
- **INV-4 Population gate.** No aggregation record is emitted for a bucket below `min_population`.
- **INV-5 Silence upward.** `receive` never raises and never returns anything but an envelope or nil.
- **INV-6 Bounded store.** Storage is capped by retention days and by size, and purge stays reachable.
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
and any `tmp/*.jsonl` telemetry output are runtime artifacts and must never be committed. Real
captured telemetry must never appear in a fixture: `spec/support/event_fixtures.rb` is synthetic and
stays that way.

## What not to comment on

RuboCop enforces style and CI runs `bundle exec rubocop` at zero offenses plus `rspec` on Ruby 3.2
and 3.3. Do not restate lint output, frozen string literal comments, line length, method length, or
formatting. Do not propose adding ActiveRecord, an MCP server, a dashboard, streaming or pub/sub, or
any dependency: the non goals in `README.md` and `CLAUDE.md` are deliberate and settled. Do not ask
for logging of dropped events beyond a count, since that is the leak vector Rule 5 closes.

## Anti-ratchet

On a re-review after new pushes the bar does not rise. Drop findings the update resolved and do not
invent new objections on unchanged lines previously accepted. Prefer a few high conviction findings.
If the change is correct, privacy safe, and bounded, reply `lgtm`. The reviewer is advisory only and
never blocks a merge: the deterministic gate is CI (rspec plus rubocop).
