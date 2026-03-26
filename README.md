# SelectoDBSQLite

SQLite adapter package for the Selecto ecosystem.

This package provides `SelectoDBSQLite.Adapter`, an external adapter module for
using Selecto against SQLite via `exqlite`.

## Installation

```elixir
def deps do
  [
    {:selecto, "~> 0.4.0"},
    {:selecto_db_sqlite, "~> 0.1.0"}
  ]
end
```

Current package version: `0.1.0`.

## Usage

Pass the adapter explicitly when configuring Selecto:

```elixir
selecto =
  Selecto.configure(domain, [database: ":memory:"],
    adapter: SelectoDBSQLite.Adapter
  )
```

You can also connect manually and pass the live connection:

```elixir
{:ok, conn} = SelectoDBSQLite.Adapter.connect(database: ":memory:")

selecto =
  Selecto.configure(domain, conn,
    adapter: SelectoDBSQLite.Adapter
  )
```

## Notes

- Placeholder style is `?`.
- Identifier quoting uses double quotes.
- Streaming is not currently supported.
- Baseline capability flags currently exposed are `:json_rowset` and
  `:sqlite_upsert`.
- `:fts5` is intentionally not claimed yet because FTS support still needs an
  explicit availability/configuration path.
- Includes adapter callbacks for `execute_raw/3`, `validate_connection/1`,
  `connection_info/1`, and `transaction/3`.

## FTS5 Field Configuration

SQLite text search is currently opt-in at the field level. Mark the target field
 as FTS-backed in the Selecto column config before using `{:text_search, ...}`.

```elixir
selecto =
  Selecto.configure(domain, conn, adapter: SelectoDBSQLite.Adapter)
  |> put_in([Access.key(:config), Access.key(:columns), "name"], %{
    name: "Name Search",
    field: :name,
    requires_join: :selecto_root,
    type: :fts5
  })

Selecto.filter(selecto, {"name", {:text_search, "wireless charger"}})
```

The builder currently accepts `type: :fts5`, `sqlite_fts5: true`, or
`text_search_backend: :fts5` as the field-level opt-in markers.

## SQLite JSON Rowsets

Selecto now includes a SQLite-oriented helper for JSON row expansion through
`json_each` and `json_tree`:

```elixir
query =
  Selecto.configure(domain, conn, adapter: SelectoDBSQLite.Adapter)
  |> Selecto.json_rowset("line_items", as: "item_rows", path: "$[*]")
  |> Selecto.select(["title", "item_rows.key", "item_rows.value"])
```

Set `function: :json_tree` to switch from `json_each` to `json_tree`.

Named query members can expose the same rowsets through `query_members.laterals`:

```elixir
domain = %{
  query_members: %{
    laterals: %{
      item_tree: %{
        source: {:json_tree, "selecto_root.metadata", nil},
        as: "item_tree",
        join_type: :inner
      }
    }
  }
}

query =
  Selecto.configure(domain, conn, adapter: SelectoDBSQLite.Adapter)
  |> Selecto.with_lateral(:item_tree)
  |> Selecto.select(["item_tree.fullkey", "item_tree.value"])
```

## Local Workspace Development

For local multi-repo development against vendored ecosystem packages, set:

```bash
SELECTO_ECOSYSTEM_USE_LOCAL=true
```

When enabled, this package resolves `{:selecto, path: "../selecto"}`.
