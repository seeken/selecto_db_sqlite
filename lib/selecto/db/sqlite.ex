defmodule Selecto.DB.SQLite do
  @moduledoc """
  Backward-compatible module name for the SQLite adapter.
  """

  defdelegate name(), to: SelectoDBSQLite.Adapter
  defdelegate connect(opts), to: SelectoDBSQLite.Adapter
  defdelegate execute(connection, query, params, opts), to: SelectoDBSQLite.Adapter
  defdelegate execute_raw(connection, query, params), to: SelectoDBSQLite.Adapter
  defdelegate placeholder(index), to: SelectoDBSQLite.Adapter
  defdelegate quote_identifier(identifier), to: SelectoDBSQLite.Adapter
  defdelegate format_datetime(sel_iodata, format), to: SelectoDBSQLite.Adapter
  defdelegate rollup_literal_order(index), to: SelectoDBSQLite.Adapter
  defdelegate rollup_sort_fix(connection), to: SelectoDBSQLite.Adapter
  defdelegate transaction(connection, fun), to: SelectoDBSQLite.Adapter
  defdelegate transaction(connection, fun, opts), to: SelectoDBSQLite.Adapter
  defdelegate supports?(feature), to: SelectoDBSQLite.Adapter
end
