# Changelog

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
