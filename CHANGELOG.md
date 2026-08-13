# Changelog

## 0.2.0 - 2026-08-12

- Added runtime-gated portable insert, update, upsert, delete, arbitrary
  `RETURNING`, atomic batch, and generated-key graph support.
- Enabled foreign-key enforcement by default for adapter-opened connections and
  retained domain-governed reference guards in each mutation.
- Added in-memory execution tests covering cardinality rollback, batch rollback,
  generated-key propagation, and reference isolation.
