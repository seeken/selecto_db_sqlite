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
- Includes adapter callbacks for `execute_raw/3`, `validate_connection/1`,
  `connection_info/1`, and `transaction/3`.

## Local Workspace Development

For local multi-repo development against vendored ecosystem packages, set:

```bash
SELECTO_ECOSYSTEM_USE_LOCAL=true
```

When enabled, this package resolves `{:selecto, path: "../selecto"}`.
