# wild-session-telemetry — Confirmed Out of Scope

**Document type:** Project planning
**Filed as:** `012-PP-PLAN-confirmed-out-of-scope.md`
**Repo:** `wild-session-telemetry`
**Status:** Active
**Last updated:** 2026-03-19
**Blueprint reference:** `001-PP-PLAN-repo-blueprint.md`

---

## 1. Purpose

This document reconfirms the non-goals established in the repo blueprint (doc 001) and validated through v1 implementation. These items are explicitly out of scope and will not be added without a documented decision to revisit.

---

## 2. Confirmed Non-Goals

### 2.1 MCP Server

**Status:** Permanently out of scope.

This library is a pure Ruby gem consumed by upstream repos that own their MCP layers. Adding an MCP server would create circular dependencies and violate the ecosystem's separation of concerns.

### 2.2 PII Collection or Storage

**Status:** Permanently out of scope.

The entire privacy model (doc 003) is built around never collecting PII. The forbidden field list, metadata allowlists, and value type validation all enforce this. Collecting PII would require a fundamentally different architecture with access controls, consent management, and data subject rights — none of which belong in an operational telemetry library.

### 2.3 Dashboard or Visualization

**Status:** Permanently out of scope.

The library produces export files. Visualization is the responsibility of downstream consumers or separate tools. Adding a UI would require web framework dependencies that contradict the pure-library design.

### 2.4 Transcript Normalization

**Status:** Out of scope. Belongs to `wild-transcript-pipeline`.

### 2.5 Gap Analysis

**Status:** Out of scope. Belongs to `wild-gap-miner`.

### 2.6 Generic Event Bus or Message Broker

**Status:** Permanently out of scope.

The library receives events through a simple `receive(event)` interface. It does not route, fan-out, or broker events. Adding broker functionality would bloat the library and create operational complexity.

### 2.7 Replacement for Per-Repo Audit Trails

**Status:** Permanently out of scope.

Audit logs in admin-tools-mcp are authoritative forensic records. Telemetry is a derived, sparse operational summary. The two serve different purposes and must remain separate.

### 2.8 Real-Time Streaming or Pub/Sub

**Status:** Permanently out of scope for v1. Low-priority v2 candidate at best.

The library is batch-oriented: receive events, store, query, export. Real-time streaming would require a fundamentally different architecture.

### 2.9 ActiveRecord or Database Dependencies

**Status:** Permanently out of scope.

The library uses flat-file storage (JSON Lines) and in-memory storage. Adding database dependencies would complicate deployment and contradict the pure-library design.

### 2.10 Multi-Tenant Isolation

**Status:** Out of scope.

The library is designed for single-deployment use. Multi-tenant isolation would require per-tenant stores, per-tenant configuration, and per-tenant privacy controls — complexity that is not justified by current use cases.

---

## 3. Decision Process for Scope Changes

If a future need arises that conflicts with these non-goals:

1. Document the need in a new architecture decision doc
2. Evaluate whether the need belongs in this repo or a new repo
3. If it belongs here, create a new epic with explicit scope justification
4. Update this document to reflect the change
