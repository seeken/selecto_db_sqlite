# Changelog

## Unreleased

- Check generated graph edges and protected child snapshots against the physical
  parent and child affinities and built-in collations before hydration or graph
  DML. Refuse unprovable ownership, including mismatched collations, affinities
  and `ANY`, rather than mutate or expose another parent's child.
  Include empty owned-set cleanup and rollback-only prepared previews.
  Governed generated-key graphs require SQLite 3.37+ for catalog admission.
- Preserve SQLite's ASCII-only identifier/type folding when reading physical
  column collations; parse unquoted Unicode and `$` identifiers and refuse a
  catalog whose actual columns lack parsed comparison metadata.

- Add bounded native grouped-prefix rollup lowering through the core's optional
  whole-query adapter callback. Preserve scope, joins, CTE markers, GROUPING masks,
  empty totals and numeric output types; apply final sorting and pagination once.

- Compare JSON containment numbers exactly from original decimal tokens using a
  bundled Apache-2.0 C extension, including integers beyond SQLite's integer
  range. Preserve final duplicate keys, Unicode/NUL keys and strict nested
  shapes; bound parsing and comparison work with explicit resource refusals.
  Package native source and build it with `elixir_make`, install it on newly
  opened or adopted Exqlite connections, and disable loading after setup.
  Include NMake/MSVC and GNU/MinGW DLL builds with explicit initializer exports.
- Correct ordinary JSON object/scalar-array predicates with type-aware null,
  boolean, numeric and text comparisons, object/array guards, empty-object and
  empty-any/all semantics, and recursive object/array containment with bound keys.
- Add computed casts/JSON text/fractional division, ISO calendar/date operations,
  UTC epoch conversion, negative numeric/date/text buckets, ordered/distinct
  aggregates, JSON-backed array predicates and native array rowsets.
- Report connected version/compile options and extension probes, and refuse
  unsupported JSON, FTS5, aggregate-order and calendar-shift operations.
- Preserve read-only query state with serialized per-connection ownership across
  public reads and stream enumeration, including errors and consumer termination.
- Enforce captured-query insert admission using actual storage affinity and
  collation; reject unprovable transforms/defaults/triggers before writes.
- Apply and validate documented connection pragmas, driver modes and native
  extension loading; fail setup on invalid options or failed extensions.
- Add incremental deadline-aware row streams, structured relation/column/key/
  index introspection and SQLite query-plan analysis. Keep legacy adapter-name
  delegates consistent with the public ports.
- Interrupt timed-out SQLite execution, and preserve caller-owned transactions
  with isolated savepoints on success, failure and exception paths.
- Replace the file-backed competing-writer test with shared in-memory lock
  refusal/retry coverage; all SQLite test databases remain in memory.

- `execute_write/3` and `execute_prepared_write/3` refuse a write without the
  `Selecto.Write.Authorization` the governed entry point (`SelectoUpdato`)
  issued for exactly that command, batch or graph, with `:ungoverned_write` and
  no row changed. The raw implementation moved to `execute_write_unsafe/3` and
  `execute_prepared_write_unsafe/3`, for trusted tooling and adapter tests
  only.

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
