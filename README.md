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
|> Selecto.from_cte("recent_orders")
|> Selecto.execute()
```

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
selecto
|> Selecto.from("articles_fts")
|> Selecto.filter({"articles_fts", {:match, "search terms"}})
|> Selecto.execute()
```

### Attach Database
```elixir
{:ok, _} = Selecto.DB.SQLite.execute(
  conn,
  "ATTACH DATABASE 'other.db' AS other",
  [],
  []
)

# Query from attached database
selecto
|> Selecto.from("other.table_name")
|> Selecto.execute()
```

## Performance Tips

1. **Use WAL mode** for better concurrency
2. **Increase cache size** for read-heavy workloads
3. **Use indexes** for frequently queried columns
4. **VACUUM periodically** to defragment the database
5. **Use prepared statements** for repeated queries
6. **Consider in-memory** databases for temporary data

## License

Apache 2.0
