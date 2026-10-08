defmodule Selecto.DB.SQLite do
  @moduledoc """
  Backward-compatible module name for the SQLite adapter.
  """

  defdelegate name(), to: SelectoDBSQLite.Adapter
  defdelegate adapter_contract_version(), to: SelectoDBSQLite.Adapter
  defdelegate dialect(), to: SelectoDBSQLite.Adapter
  defdelegate capability(feature), to: SelectoDBSQLite.Adapter
  defdelegate normalize_type(type), to: SelectoDBSQLite.Adapter
  defdelegate type_family(type), to: SelectoDBSQLite.Adapter
  defdelegate normalize_execution_result(result), to: SelectoDBSQLite.Adapter
  defdelegate normalize_error(error), to: SelectoDBSQLite.Adapter
  defdelegate connect(opts), to: SelectoDBSQLite.Adapter
  defdelegate disconnect(connection), to: SelectoDBSQLite.Adapter
  defdelegate execute(connection, query, params, opts), to: SelectoDBSQLite.Adapter
  defdelegate execute_raw(connection, query, params), to: SelectoDBSQLite.Adapter
  defdelegate execute_query(connection, query, params, opts), to: SelectoDBSQLite.Adapter
  defdelegate stream(connection, query, params, opts), to: SelectoDBSQLite.Adapter
  defdelegate validate_connection(connection), to: SelectoDBSQLite.Adapter
  defdelegate connection_info(connection), to: SelectoDBSQLite.Adapter
  defdelegate connection_capabilities(connection), to: SelectoDBSQLite.Adapter
  defdelegate supports?(connection, feature), to: SelectoDBSQLite.Adapter
  defdelegate list_tables(connection, opts \\ []), to: SelectoDBSQLite.Adapter
  defdelegate list_relations(connection, opts \\ []), to: SelectoDBSQLite.Adapter
  defdelegate introspect_table(connection, table, opts \\ []), to: SelectoDBSQLite.Adapter
  defdelegate analyze_query(selecto, opts \\ []), to: SelectoDBSQLite.Adapter
  defdelegate write_capabilities(connection), to: SelectoDBSQLite.Adapter
  defdelegate preview_write(connection, write, opts \\ []), to: SelectoDBSQLite.Adapter
  defdelegate execute_write(connection, write, opts \\ []), to: SelectoDBSQLite.Adapter
  defdelegate execute_write_unsafe(connection, write, opts \\ []), to: SelectoDBSQLite.Adapter

  defdelegate execute_prepared_write(connection, prepare_fun, opts \\ []),
    to: SelectoDBSQLite.Adapter

  defdelegate execute_prepared_write_unsafe(connection, prepare_fun, opts \\ []),
    to: SelectoDBSQLite.Adapter

  defdelegate placeholder(index), to: SelectoDBSQLite.Adapter
  defdelegate quote_identifier(identifier), to: SelectoDBSQLite.Adapter
  defdelegate format_datetime(sel_iodata, format), to: SelectoDBSQLite.Adapter
  defdelegate rollup_literal_order(index), to: SelectoDBSQLite.Adapter
  defdelegate rollup_sort_fix(connection), to: SelectoDBSQLite.Adapter
  defdelegate render_rollup(selecto, opts), to: SelectoDBSQLite.Adapter
  defdelegate transaction(connection, fun), to: SelectoDBSQLite.Adapter
  defdelegate transaction(connection, fun, opts), to: SelectoDBSQLite.Adapter
  defdelegate supports?(feature), to: SelectoDBSQLite.Adapter
end
