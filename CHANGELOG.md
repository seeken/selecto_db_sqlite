# Changelog

## Unreleased

- Reject releases containing native ObjectId fields, including unselected fields
  and counts, at capability preflight and direct document compilation.

- Added optional owned object relations with native predicates, tenant-scoped
  parent identity, same-input whole-parent validation, and duplicate-parent
  rejection. Root reads and counts enforce the new object shape refinements.

- Added explicitly granted scalar-array contains/any/all predicates with native
  parameterized JSON membership, strict types, whole-array bounds, and set semantics.
- Validate bounded UTF-8 bytes natively before scalar-array membership, including
  malformed encodings that SQLite can otherwise retain as text.

- Added explicitly granted root count and integer sum/min/max with native SQL
  totals, bounded same-statement validation evidence, and exact empty/null behavior.

- Added an experimental JSON document query adapter for Selecto's source-query
  plan, with exact missing/null behavior, trusted tenant scope, signed cursors
  and verified index-backed root ordering. Existing SQL APIs are unchanged.

## 0.5.0 - 2026-08-14

- Removed renderer aliases for the retired `json_extract_path` and
  `json_extract_path_text` core operations.
- Raised the Selecto baseline to `0.5.0` and implemented the explicit runtime,
  normalized result/error/type, and SQLite-owned dialect-fragment ports.
- Unsupported PostgreSQL-shaped features now fail with structured capability
  evidence instead of inheriting core fallback SQL.
- SQLite now owns portable datetime-format and case-insensitive comparison
  rendering and explicitly rejects unsupported timezone/epoch conversion.

## 0.2.0 - 2026-08-12

- Added runtime-gated portable insert, update, upsert, delete, arbitrary
  `RETURNING`, atomic batch, and generated-key graph support.
- Enabled foreign-key enforcement by default for adapter-opened connections and
  retained domain-governed reference guards in each mutation.
- Added in-memory execution tests covering cardinality rollback, batch rollback,
  generated-key propagation, and reference isolation.
