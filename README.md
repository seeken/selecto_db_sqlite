# Selecto SQLite Adapter

SQLite adapter for the Selecto query builder.

## Installation

Add `selecto_db_sqlite` to your list of dependencies:

```elixir
def deps do
  [
    {:selecto, ">= 0.5.0 and < 0.6.0"},
    {:selecto_db_sqlite, "~> 0.2"},
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
- ✅ Window functions (SQLite 3.25+)
- ✅ JSON operations (JSON1 extension)
- ✅ Full-text search (FTS5 extension)
- ✅ Savepoints
- ✅ In-memory databases
- ✅ Attached databases
- ✅ EXPLAIN QUERY PLAN
- ✅ Portable insert, update, upsert, and delete
- ✅ Atomic write batches
- ✅ `RETURNING` and generated-key graphs on SQLite 3.35+

### Limitations
- ❌ RIGHT JOIN (emulate with LEFT JOIN)
- ❌ FULL OUTER JOIN (emulate with UNION)
- ❌ Stored procedures
- ❌ LATERAL joins
- ❌ Native array types (use JSON)
- ❌ Limited ALTER TABLE
- ⚠️ Single writer at a time
- ⚠️ Write capabilities are probed from the connected SQLite runtime and fail
  closed when `RETURNING` is unavailable

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

## Extensions

Enable SQLite extensions:

```elixir
config = [
  database: "app.db",
  extensions: [
    "path/to/json1.so",     # JSON support
    "path/to/fts5.so"       # Full-text search
  ]
]
```

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

### Window Functions (SQLite 3.25+)
```elixir
selecto
|> Selecto.select([
  "name",
  {:window, "ROW_NUMBER() OVER (ORDER BY created_at)"}
])
|> Selecto.execute()
```

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
parameterized SQLite JSON SQL. It supports the shared root/nested-field slice;
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

The executable controls are `test/document_query_adapter_test.exs` and
`test/document_aggregate_test.exs`. This uses
SQLite's documented [JSON functions](https://www.sqlite.org/json1.html) and proves
the named synthetic subset, not general document database portability.

## License

Apache 2.0
