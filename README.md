# Selecto SQLite Adapter

SQLite adapter for the Selecto query builder.

## Installation

Add `selecto_db_sqlite` to your list of dependencies:

```elixir
def deps do
  [
    {:selecto, ">= 0.5.0 and < 0.6.0"},
    {:selecto_db_sqlite, "~> 0.5"},
    {:exqlite, "~> 0.13"}
  ]
end
```

## Configuration

```elixir
# File-based database
config = [
  database: "path/to/database.db",
  journal_mode: :wal,
  foreign_keys: :on
]

# In-memory database
config = [
  database: ":memory:",
  foreign_keys: :on
]

selecto = Selecto.configure(domain, config, adapter: SelectoDBSQLite.Adapter)
```

## Feature Support

### Supported Features
- ✅ Query execution
- ✅ Joins (INNER, LEFT, CROSS)
- ✅ CTEs and recursive CTEs
- ✅ Bounded grouped-prefix rollup, including `GROUPING` masks and empty totals
- ✅ Window functions (basic windows: SQLite 3.25+; GROUPS/newer RANGE frames: 3.28+)
- ✅ Typed recursive JSON containment, JSON extraction, and JSON rowsets (JSON support required)
- ✅ Computed casts, JSON text values, fractional decimal division, and portable buckets
- ✅ Calendar formats, date parts and truncation, ISO weeks, and UTC epoch conversion
- ✅ JSON-backed arrays and ordered/distinct aggregate collections
- ✅ Full-text search (FTS5 extension)
- ✅ Savepoints, including caller-owned transactions
- ✅ Incremental streaming with statement cleanup and deadlines
- ✅ Table/view, column, primary-key, foreign-key, and index introspection
- ✅ In-memory databases
- ✅ Attached databases
- ✅ EXPLAIN QUERY PLAN
- ✅ Portable insert, update, upsert, and delete
- ✅ Atomic write batches
- ✅ `RETURNING` on SQLite 3.35+ and admitted generated-key graphs on SQLite 3.37+

### Limitations
- The documented portable join subset is INNER, LEFT, and CROSS. SQLite itself
  supports RIGHT and FULL OUTER joins starting in 3.39.0.
- ❌ Stored procedures
- ❌ LATERAL joins
- ❌ Native array types (use JSON)
- ❌ Limited ALTER TABLE
- ⚠️ Single writer at a time
- ⚠️ Write capabilities are probed from the connected SQLite runtime and fail
  closed when `RETURNING` is unavailable
- `EXPLAIN QUERY PLAN` provides plan descriptions; SQLite has no native
  `EXPLAIN ANALYZE` or PostgreSQL plan-cost/timing fields.

The available JSON, FTS5, math, and newer SQL features depend on the connected
SQLite library's version and build. Coarse `supports?/1` flags describe adapter
ports; they do not install missing engine extensions. `connection_capabilities/1`
and `supports?(conn, feature)` report the connected version, compile options, and
JSON/FTS5/math probes. Connected renderers gate JSON, FTS5, aggregate ordering
(3.44+), and clipped month/year cutoffs (3.46+). `write_capabilities/1` also gates
UPSERT (3.24+) and RETURNING (3.35+). Use a current SQLite build for the complete
adapter feature set.

## Governed writes

Applications write through `SelectoUpdato`, which validates every command,
batch, and graph against the domain's `writes` contract and hands this adapter
a single-use `Selecto.Write.Authorization` for exactly that payload.
`execute_write/3` and `execute_prepared_write/3` refuse a write without one
with `:ungoverned_write` before any statement runs, leaving every row
unchanged. `execute_write_unsafe/3` and `execute_prepared_write_unsafe/3` skip
that check; it exists for trusted tooling and this package's own tests, never
for application code.

The adapter reports `mutation_expressions` in its write capabilities. Closed
Updato arithmetic/coalesce trees bind literals, quote governed root references,
and retain native SQLite NULL and division behavior. Typed NULL is compiled as
a bound cast. Prospective Rules use the same expression compiler against
protected prior row values before ordinary column-affinity projection; DML
retains the original expression. Trees, types and operations remain bounded by
the governed Updato compiler. Run the public in-memory regression at
`scripts/sqlite_mutation_expression_regression.exs` with the selected Updato
and certification fixture modules on the code path.

## Type Mappings

| Elixir Type | SQLite Type | Storage |
|-------------|-------------|---------|
| :string | TEXT | Dynamic |
| :text | TEXT | Dynamic |
| :integer | INTEGER | Dynamic |
| :bigint | INTEGER | Dynamic |
| :float | REAL | Dynamic |
| :decimal | NUMERIC | Dynamic |
| :boolean | INTEGER | 0/1 |
| :date | TEXT | ISO8601 |
| :datetime | TEXT | ISO8601 |
| :json | TEXT | JSON string |
| :uuid | TEXT | String |
| :binary | BLOB | Binary |

NUMERIC affinity can convert decimal text to a floating-point or integer SQLite
value. This adapter does not promise fixed-scale or arbitrary-precision decimal
storage. Ordinary JSON containment distinguishes booleans from numbers, explicit
JSON null from a missing member, and text from numeric values. General containment
accepts recursively nested objects and arrays, with bound object keys including
punctuation and quoted names (maximum nesting depth 32). Duplicate object keys
use their final value. A root array can contain an immediate primitive; nested
object/array boundaries remain strict. Scalar-array any/all
membership accepts scalar needles; nested needles in those finite operations fail
validation. An empty object matches objects, an empty array-any matches nothing,
and an empty array-all matches only valid arrays. SQL NULL propagates through
JSON predicates.

General containment uses the adapter's bundled native SQLite extension and
compares original numeric tokens as exact decimals, including integers beyond
SQLite's signed 64-bit range. It never uses SQLite REAL conversion for containment.
The extension is independently authored under Apache-2.0 and built from packaged
C source by `elixir_make`; building the adapter requires `make` and a C11 compiler.
The SQLite headers come from the existing Exqlite dependency. No system SQLite
library is linked into the extension. Connection setup loads only the bundled
library automatically and disables extension loading afterward. Adopting an
Exqlite reference with `Adapter.connect/1` installs and probes the same function;
a provider that cannot install it returns `:sqlite_exact_json_extension_unavailable`.
`json_contains` is advertised only after live exact-number and shape probes pass.

Containment accepts canonical JSON text, including escaped NUL and Unicode
object keys. Binary SQLite JSONB is not a supported storage representation.
Malformed source text returns false; SQL NULL remains NULL. Native calls bound
each source/needle to 1 MiB, nesting to 32, combined values to 32,768 nodes,
allocated parser memory to 16 MiB, and parser/comparison work to 8,388,608 units.
Exceeding a native limit raises an explicit SQLite error, normalized to the safe
`:json_containment_resource_limit` category. Invalid or oversized caller needles
fail query validation. Plain maps accept string or atom keys, with collisions
after conversion to strings refused; arbitrary structs are refused.

`sh scripts/verify_native_json.sh` runs the independent parser/comparator consumer
with AddressSanitizer and UndefinedBehaviorSanitizer using an in-memory SQLite
database. `SQLITE_HEADERS` and `SQLITE_LIB_DIR` may select the test consumer's
headers and a SQLite library with extension loading enabled.

Windows builds include `Makefile.win` for `elixir_make`'s NMake selection and
produce `selecto_json_contains.dll`, with an explicit undecorated SQLite entry
point export. Run Mix from a Visual Studio developer command prompt with a
C11-capable MSVC toolchain (Visual Studio 2019 16.8 or newer). The API pointer
uses MSVC interlocked intrinsics instead of experimental C11 atomics. GNU Make
with a compatible MinGW compiler is also supported by the Unix makefile's
`Windows_NT` branch. Windows x64/x86 DLLs have been cross-built and their
initializer exports inspected; the MSVC branch has passed Windows-target syntax
checks for x64, ARM64 and x86. Native execution has currently been verified on
Darwin; actual MSVC/NMake execution and Windows runtime tests await a Windows CI
host.

Array values use JSON storage. Constructors, one-dimensional length/cardinality,
typed contains/overlap/contained/equality predicates, and native `json_each`
rowsets are supported. JSON array aggregates retain nulls and support DISTINCT
and ordering. String aggregates support bound separators and ordering; DISTINCT
requires SQLite's comma separator. Multidimensional array-specific operations
and correlated LATERAL subqueries remain unsupported.

Datetime operations accept UTC storage and output zones, including Unix seconds
and milliseconds. ISO weeks use the ISO year at January/December boundaries,
and week truncation starts on Monday. Unknown formats, symbolic age intervals,
microsecond extraction, and IANA timezone conversion fail validation. SQLite
keeps millisecond timestamp precision; decimal division uses floating point.
Numeric buckets floor negative values without requiring optional math functions.
Text normalization respects the configured article list and case policy.

SQLite rollup is emulated by a single `UNION ALL` statement over the grouped
prefixes of one to eight distinct field dimensions. Every branch retains the
original eligible source rows, required filters, CTEs and joins, including joins
needed by unselected dimensions. `GROUPING` supports unique subsets of those
dimensions and distinguishes a real NULL key from a subtotal. Empty input still
produces one grand total. Up to sixty-four output selectors may be dimensions,
COUNT/SUM/AVG/MIN/MAX aggregates, aggregate COALESCE, literals or GROUPING.
Final sorting references selected outputs and preserves SQLite numeric ordering;
limit and offset apply once to the combined result. Mixed grouping specifications,
filtered aggregates, window outputs, array operations, separate JSON projections
and subselect outputs are refused.
The connected `rollup` capability requires CTE support (SQLite 3.8.3+); it describes
this adapter lowering, not native SQLite ROLLUP syntax.

## SQLite Pragmas

Configure SQLite behavior with pragmas:

```elixir
config = [
  database: "app.db",
  journal_mode: :wal,        # Write-ahead logging
  cache_size: -2000,         # 2MB cache
  foreign_keys: :on,         # Enable foreign keys
  busy_timeout: 5000,        # 5 second timeout
  synchronous: :normal,      # Sync mode
  temp_store: :memory        # Temp tables in memory
]
```

All shown options are validated and applied. `foreign_keys` defaults to `:on`.
`mode` accepts Exqlite's `:readonly`, `:readwrite`, `:create`, or compatible mode
lists. Invalid or unknown connection options return an error before opening the
database. SQLite may retain a supported journal mode instead of the requested
one: in-memory databases retain `memory` when `:wal` is requested. Read back
`PRAGMA journal_mode` to inspect the effective setting.

## Extensions

Load trusted native SQLite extensions:

```elixir
config = [
  database: "app.db",
  extensions: [
    "/absolute/path/to/custom_extension.so"
  ]
]
```

Paths must name existing native libraries. Loading failures fail connection
setup; extension loading is disabled again after configuration. Modern SQLite
normally includes JSON support, and bundled FTS5 builds need no loadable library.

## Examples

### Basic Query
```elixir
selecto
|> Selecto.select(["name", "email"])
|> Selecto.filter({"active", 1})
|> Selecto.execute()
```

### With CTE
```elixir
selecto
|> Selecto.with_cte("recent_orders", fn s ->
  s
  |> Selecto.select(["id", "user_id", "total"])
  |> Selecto.filter({"created_at", ">", "2024-01-01"})
end)
|> Selecto.select(["id"])
|> Selecto.execute()
```

The configured domain remains the root relation; the CTE is an additional
governed query member rather than a replacement `FROM` source.

### Window Functions
```elixir
selecto
|> Selecto.select(["name"])
|> Selecto.window_function(:row_number,
  over: [order_by: ["created_at"]], as: "row_number")
|> Selecto.execute()
```

### Streaming, Introspection, and Query Plans

```elixir
{:ok, stream} = Selecto.execute_stream(selecto, timeout: 5_000)
first_ten = Enum.take(stream, 10)

{:ok, tables} = SelectoDBSQLite.Adapter.list_tables(conn)
{:ok, metadata} = SelectoDBSQLite.Adapter.introspect_table(conn, "orders")
{:ok, plan} = Selecto.Performance.QueryAnalyzer.get_query_plan(selecto)
```

The stream fetches rows incrementally and releases its statement on early halt,
completion, or error. Each enumeration starts a new statement; consume it before
closing the connection. Its deadline includes consumer time between rows.
Introspection defaults to schema `"main"`; pass `schema: "temp"` or an attached
database name when needed. Foreign-key and index metadata retain composite-key
positions and SQLite actions.

Public engine reads use `execute_query/4`, which preserves the caller's
`PRAGMA query_only` state. Streams hold this read-only guard while enumerated;
concurrent governed reads on one connection wait for the owner to finish.
Completion, errors, early halt, and consumer termination restore saved state.
Consume or halt a stream before closing its connection. Adapter `execute/4` and
`execute_raw/3` remain trusted administrative ports for fixture setup and tooling.
External native-driver operations can bypass this ownership protocol.

Captured-query inserts prove the guard against canonical candidate values using
the table's actual affinity and BINARY/NOCASE/RTRIM collation before DML. Guarded
fields must be supplied explicitly. Unsupported types, generated/default-dependent
guard fields, triggers, views/virtual or shadow tables, generated columns anywhere
in the table, and case-insensitive TEMP table/view shadows fail with
`query_rule_not_evaluable`; false/NULL guards return `query_rule_violation`.
No row is changed on refusal. Ordinary storage proof uses `PRAGMA table_list`
and requires SQLite 3.37 or later; the live capability reflects that version
floor. Fixed-scale insert precision remains unsupported.

All SQLite tests use `:memory:` databases, or a named
`file:name?mode=memory&cache=shared` URI when separate handles must share state.

### Full-Text Search (FTS5)
```elixir
articles_fts_selecto
|> Selecto.filter({"articles_fts", {:match, "search terms"}})
|> Selecto.execute()
```

Configure `articles_fts_selecto` with a domain whose
`source.source_table` is `"articles_fts"`.

### Attach Database
```elixir
{:ok, _} = Selecto.DB.SQLite.execute(
  conn,
  "ATTACH DATABASE 'other.db' AS other",
  [],
  []
)

# Configure this Selecto instance from a domain whose source table is
# "other.table_name".
attached_selecto
|> Selecto.select(["id"])
|> Selecto.execute()
```

## Performance Tips

1. **Use WAL mode** for better concurrency
2. **Increase cache size** for read-heavy workloads
3. **Use indexes** for frequently queried columns
4. **VACUUM periodically** to defragment the database
5. **Use prepared statements** for repeated queries
6. **Consider in-memory** databases for temporary data

## Experimental document query control

`SelectoDBSQLite.DocumentQueryAdapter` lowers the new portable document plan to
parameterized SQLite JSON SQL. It supports root/nested fields and optional owned
object relations;
array relation execution is explicitly unsupported in this SQL control. It
requires the development Selecto source-query API, which is not yet a separately
published version.

The host supplies a table declared in `ShapeRelease.source.sql_table`, with a
JSON text `document` column and the declared expression index. For the synthetic
work-order release, explicit fixture setup is:

```sql
CREATE TABLE work_orders (document TEXT NOT NULL);
CREATE UNIQUE INDEX tenant_identity ON work_orders (
  json_extract(document, '$."tenant_id"'),
  json_extract(document, '$."_id"')
);
```

Insert `Selecto.Document.Fixtures.work_orders/0` as JSON with bound parameters,
then execute an approved plan through
`Selecto.execute_plan(plan, SelectoDBSQLite.DocumentQueryAdapter, connection,
cursor_secret: host_key)`. The adapter verifies an indexed search and rejects
temporary sorts. Projection is bounded result normalization after SQL filters,
ordering and pagination. It validates fetched documents against the approved
release and retains missing values distinctly from null.

Approved root aggregates use `%{"aggregate" => [%{"op" => "count", "as" => "total"}]}` or explicit integer `sum`, `min`, and `max` grants.
`Selecto.Document.Fixtures.aggregate_release/0` is a separate synthetic release
with these grants; older releases do not grant aggregates implicitly. Aggregates
return exactly one row, with count zero and numeric totals null on empty input.
Missing and null numeric inputs are excluded. Row selection and cursor options
cannot be combined with aggregates.

A materialized candidate CTE caps matching input at `max_input_rows + 1` and
feeds both native SQL totals and local shape/integer validation evidence in the
same statement. Exceeding the input or byte bound rejects the query. No partial
total is returned. Sum inputs must have absolute value at most
`floor(9007199254740991 / max_input_rows)`; min/max inputs use the full portable
integer range. Validation evidence is bounded local work; totals are native SQL.

Typed scalar-array fields may explicitly grant `contains`, `contains_any`, and
`contains_all` through a `scalar_array` descriptor. The separate
`Selecto.Document.Fixtures.scalar_array_release/0` demonstrates string, integer,
and boolean elements. These grants remain independent of ordinary `filterable`
and `sortable` permissions. For example:

```elixir
%{"where" => %{"field" => "tags", "op" => "contains_any", "value" => ["urgent", "routine"]}}
```

Membership executes natively through parameterized `json_each` expressions.
Arrays must be present, wholly well typed, and within their declared element
bound (maximum 1,000); invalid or missing/null arrays do not match. No truncated
prefix is accepted. Duplicate values have set semantics. An empty requested
`contains_any` set is false; an empty `contains_all` set is true only for a valid
array, including an empty array. Strings use binary comparison and a 16,384-byte
bound. A bounded native byte walk rejects malformed UTF-8, surrogate encodings,
overlong sequences and values above U+10FFFF while preserving embedded nulls.
Integers use the portable signed 53-bit range, and booleans do not coerce
to integers. Floating-point and nested/object elements remain unsupported.

If another predicate branch selects an invalid document, full ShapeRelease
validation still rejects it. Even count queries require `document.scalar_array`
when the release declares typed arrays; older adapters cannot ignore these
refinements. SQLite still does not execute identified-child relations.

An approved `kind: "object"` relation exposes one owned embedded object through
published object-relative fields. `Fixtures.object_relation_release/0` publishes
`work_order_schedule`; query it with a required `parent_identity` and trusted
tenant context. Results contain zero or one row, with the parent identity in
`metadata["relation_identity"]`. No synthetic identity column is added. Missing
or null objects produce no row only when the approved shape permits them; a
valid empty object still produces one row. Cursors, ordering, aggregates, and
limits other than one are unsupported for this relation.

A materialized CTE selects at most two parents under the tenant and identity
index. Duplicate parents fail cardinality validation. Native SQL evaluates the
child predicate against this same input, while complete parent evidence is
validated before its match flag is honored. A false predicate cannot hide an
invalid parent, child object, or typed array. Parent evidence and returned rows
must fit the byte bound; this is not a hard limit on SQLite's internal parsing
or storage memory. Root reads and counts also validate owned object fields, and
the release-wide `document.object_relation` capability prevents an older adapter
from ignoring them. Existing writes and array relation support are unchanged.

Native `object_id` fields require `document.object_id`, which this SQLite JSON
control does not advertise. Any release containing that type is rejected,
including counts and projections that omit the field. Direct compilation also
rejects it; tagged JSON values are not treated as native BSON identities.

The executable controls are `test/document_query_adapter_test.exs`,
`test/document_aggregate_test.exs`, `test/document_scalar_array_test.exs`, and
`test/document_object_relation_test.exs`. This uses
SQLite's documented [JSON functions](https://www.sqlite.org/json1.html) and proves
the named synthetic subset, not general document database portability.

## License

Apache 2.0

Canonical storage-dependent data rules use adapter-owned prepared transactions on SQLite
3.37 or newer. A rollback-only private TEMP row applies the physical column's
actual affinity and built-in collation before candidate and transaction rules
run. Protected updates load declared source fields and scoped collection deltas
load at most 1,000 children. Stored normalizers retain field grants and write-once
guards; repeated selectors for one physical row refuse stale snapshots. Public
prepared previews use the same native projection and preserve host transactions.

Connected previews and ordinary/final prepared commands first prove every
mutating target is an ordinary main table with no generated or hidden columns,
main/TEMP target triggers, or TEMP table/view shadow. This applies to insert,
update, upsert and delete, even without Rules, including every later batch or
graph target and delete-missing cleanup before the first business statement.
Read-only queries do not acquire mutation rights. Logical preview validation
retains its diagnostic precedence. The physical proof also checks incoming
main-schema foreign keys. An update or upsert that assigns a referenced
key refuses with `native_write_effects_not_evaluable` when SQLite would apply
`ON UPDATE CASCADE`, `SET NULL`, or `SET DEFAULT` outside the approved commands.
This includes a normalizer changing a field that was not originally submitted.
The check uses the actual upsert conflict-update field list, physical implicit
primary-key targets and SQLite's ASCII identifier comparison. Unassigned keys
and `NO ACTION`/`RESTRICT` keep their normal behavior. The protected catalog scan
is bounded to 1,024 main tables and 4,096 foreign-key rows; unavailable or
exhausted evidence refuses. This is a finite prepared-write admission check;
it does not authorize arbitrary foreign-key cascades. Deletes with automatic
incoming actions require actual scoped reads proving there are no referencing
children. The entire batch or graph, including delete-missing cleanup, is
checked before its first mutation. An unmaterialized cleanup requires global
absence; sibling writes to an incoming child table and main/TEMP triggers on
plan targets refuse because they can invalidate that proof. TEMP target shadows
also refuse. These are finite native admission boundaries; attached-schema
effects are not established by this check. Public native
controls are available in `scripts/sqlite_incoming_fk_regression.exs` and
`scripts/sqlite_delete_effects_regression.exs` with the selected Updato dependency.

Native rule admission refuses trigger-bearing targets, any generated or hidden
column, virtual/shadow tables, TEMP catalog shadows, custom collations, ambiguous
storage types, and unresolved generated values or required external evidence.
Upsert and delete rules requiring a final candidate remain explicit refusals.
All SQLite tests use in-memory databases.

The ordinary-source proof also rejects physical schema `ON CONFLICT REPLACE`
clauses. Even a plain INSERT could otherwise delete a conflicting row and invoke
unrelated incoming DELETE actions, or substitute a NOT NULL default outside the
captured candidate. This refusal covers every mutating target before any batch or
graph prefix executes, including connected prepared preview. Quoted strings,
quoted identifiers and comments containing those words are accepted as data;
comments separating a real conflict clause do not conceal it. The shared
physical catalog proof also applies to owned-schema comparison and candidate
snapshot loading. Ordinary SELECT queries remain available. This is a conservative
storage refusal, not emulation of arbitrary replacement effects.

Generated-key graphs and protected child snapshots validate the physical parent
and child ownership columns before hydration or graph DML. SQLite foreign keys
compare with the parent's affinity and collation, while child predicates compare
with the child's. This adapter admits those predicates only when both columns
have the same SQLite affinity and built-in collation (`BINARY`, `NOCASE`, or
`RTRIM`). Different type spellings with the same affinity, such as `TEXT` and
`VARCHAR`, are supported. The parent key must also have a single-column,
nonpartial physical unique index with the same comparator, or be an actual
`INTEGER PRIMARY KEY` rowid alias. A composite, expression or differently
collated index does not establish that identity. Domain-declared edges without
a physical foreign key remain supported when that proof succeeds. Every
foreign-key group involving the child ownership column, when present, must
match the declared single-column parent edge; contradictory or composite
foreign keys refuse. An omitted referenced field resolves only a sole physical
parent primary key.

A mismatch, unproved uniqueness, `ANY` storage, or an unavailable ordinary
main-schema catalog refuses with `owned_key_comparison_not_evaluable`; it never
uses a child's broader comparison to claim ownership of another parent's row.
The check also covers empty delete-missing sets and prepared previews, inside
the original connection's write transaction. Applications using mismatched
physical ownership columns must align their schema before using this finite
owned-graph port.
Both protected snapshot loaders use the same proof before exposing children.
Updato's collection provider preserves its existing generic
`candidate_state_unavailable` diagnostic when physical evidence is unavailable;
the individual record provider retains the adapter error.

Prospective availability is checked independently of a rule's enforcement or
condition. A consumed NULL or omitted true rowid alias remains unknown before
INSERT, including an `INTEGER PRIMARY KEY DEFAULT` declaration. Catalog proof
uses WITHOUT ROWID and physical primary-key index metadata to distinguish the
column `INTEGER PRIMARY KEY DESC` exception and `INT PRIMARY KEY`, which store
genuine NULL. Unconsumed generated identity is retained as intent without
fabricating a projected value. Omitted ordinary nullable fields without defaults
are known SQL NULL; unproved default dependencies remain pending.
Protected `graph_domain_inference` supplies creation-only native relationship
metadata for the public Updato direct-write bridge. It requires declared insert
grants, actual ordinary `main` tables, a NOT NULL single foreign key, and a
unique parent with compatible key storage. It derives child cardinality from
native uniqueness and rechecks the inferred edges before graph dispatch.
`scripts/sqlite_direct_graph_inference_regression.exs` exercises in-memory
graph creation, missing-proof refusals, scope isolation and late rollback.
