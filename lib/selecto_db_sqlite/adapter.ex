defmodule SelectoDBSQLite.Adapter do
  @moduledoc """
  Read/query SQLite adapter for Selecto.

  This module does not implement `Selecto.DB.WriteAdapter`; portable writes
  remain unavailable until a dedicated write implementation is added.
  """

  @behaviour Selecto.DB.Adapter

  @missing_dependency {:adapter_dependency_missing, :exqlite}

  @impl true
  def name, do: :sqlite

  @impl true
  def connect(connection) when is_reference(connection), do: {:ok, connection}
  def connect(opts) when is_map(opts), do: connect(Map.to_list(opts))

  def connect(opts) when is_list(opts) do
    with :ok <- ensure_exqlite() do
      database = Keyword.get(opts, :database, ":memory:")
      Exqlite.Sqlite3.open(database)
    end
  end

  def connect(other), do: {:error, {:invalid_connection_options, other}}

  @impl true
  def execute(connection, query, params, opts) do
    with :ok <- ensure_exqlite() do
      connection = unwrap_connection(connection)
      timeout = Keyword.get(opts, :timeout, 5_000)
      sqlite_query = query |> normalize_query() |> convert_parameters(params || [])

      with {:ok, statement} <- Exqlite.Sqlite3.prepare(connection, sqlite_query),
           :ok <- Exqlite.Sqlite3.bind(statement, params || []),
           {:ok, columns} <- Exqlite.Sqlite3.columns(connection, statement),
           {:ok, rows} <- fetch_all(connection, statement, timeout) do
        {:ok, %{columns: columns || [], rows: rows, num_rows: length(rows), metadata: %{}}}
      end
    end
  end

  @impl true
  def execute_raw(connection, query, params), do: execute(connection, query, params, [])

  @impl true
  def placeholder(_index), do: "?"

  @impl true
  def quote_identifier(identifier) do
    escaped = identifier |> to_string() |> String.replace("\"", "\"\"")
    "\"#{escaped}\""
  end

  @impl true
  def format_datetime(sel_iodata, "YYYY"), do: ["strftime('%Y', ", sel_iodata, ")"]
  def format_datetime(sel_iodata, "MM"), do: ["strftime('%m', ", sel_iodata, ")"]
  def format_datetime(sel_iodata, "DD"), do: ["strftime('%d', ", sel_iodata, ")"]
  def format_datetime(sel_iodata, "HH24"), do: ["strftime('%H', ", sel_iodata, ")"]
  def format_datetime(sel_iodata, _format), do: ["CAST(", sel_iodata, " AS TEXT)"]

  @impl true
  def rollup_literal_order(index), do: [Integer.to_string(index), " asc"]

  @impl true
  def rollup_sort_fix(_connection), do: false

  def transaction(conn, fun), do: transaction(conn, fun, [])

  @impl true
  def transaction(conn, fun, _opts) do
    with {:ok, _} <- execute(conn, "BEGIN", [], []) do
      try do
        conn
        |> fun.()
        |> finish_transaction(conn)
      rescue
        exception ->
          _ = execute(conn, "ROLLBACK", [], [])
          reraise exception, __STACKTRACE__
      end
    end
  end

  @impl true
  def supports?(:json_rowset), do: true
  def supports?(:window_functions), do: true
  def supports?(:cte), do: true
  def supports?(:recursive_cte), do: true
  def supports?(:returning), do: false
  def supports?(:rollup), do: false
  def supports?(:stream), do: false
  def supports?(_feature), do: false

  defp rollback_after_error(conn, error) do
    _ = execute(conn, "ROLLBACK", [], [])
    error
  end

  defp finish_transaction({:error, _reason} = error, conn) do
    rollback_after_error(conn, error)
  end

  defp finish_transaction(result, conn) do
    case execute(conn, "COMMIT", [], []) do
      {:ok, _} -> {:ok, result}
      error -> rollback_after_error(conn, error)
    end
  end

  defp ensure_exqlite do
    if Code.ensure_loaded?(Exqlite.Sqlite3), do: :ok, else: {:error, @missing_dependency}
  end

  defp unwrap_connection(%{connection: connection}), do: connection
  defp unwrap_connection(connection), do: connection

  defp normalize_query(query) when is_binary(query), do: query
  defp normalize_query(query), do: IO.iodata_to_binary(query)

  defp fetch_all(db, statement, timeout) do
    task = Task.async(fn -> fetch_rows(db, statement, []) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp fetch_rows(db, statement, acc) do
    case Exqlite.Sqlite3.step(db, statement) do
      {:row, row} -> fetch_rows(db, statement, [row | acc])
      :done -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp convert_parameters(query, []), do: query

  defp convert_parameters(query, params) do
    params
    |> Enum.with_index(1)
    |> Enum.reduce(query, fn {_param, index}, acc -> String.replace(acc, "$#{index}", "?") end)
  end
end
