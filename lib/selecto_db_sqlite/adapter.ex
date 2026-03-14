defmodule SelectoDBSQLite.Adapter do
  @moduledoc """
  SQLite adapter for Selecto backed by `Exqlite`.
  """

  @behaviour Selecto.DB.Adapter

  @missing_dependency {:adapter_dependency_missing, :exqlite}

  @impl true
  def name, do: :sqlite

  @impl true
  def connect(connection) when is_reference(connection), do: {:ok, connection}
  def connect(connection) when is_pid(connection) or is_atom(connection), do: {:ok, connection}
  def connect(connection) when is_map(connection), do: connect(Map.to_list(connection))

  def connect(opts) when is_list(opts) do
    if dependency_available?() do
      database = Keyword.get(opts, :database) || Keyword.get(opts, :path) || ":memory:"
      mode = Keyword.get(opts, :mode, :readwrite)

      case Exqlite.Sqlite3.open(database, mode: mode) do
        {:ok, conn} -> {:ok, conn}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, @missing_dependency}
    end
  end

  def connect(other), do: {:error, {:invalid_connection_options, other}}

  @impl true
  def execute(connection, query, params, _opts) do
    resolved_connection = resolve_connection(connection)

    cond do
      not dependency_available?() ->
        {:error, @missing_dependency}

      not is_reference(resolved_connection) ->
        {:error, {:invalid_connection, connection}}

      true ->
        execute_statement(resolved_connection, normalize_query(query), params || [])
    end
  end

  @impl true
  def execute_raw(connection, query, params) do
    execute(connection, query, params, [])
  end

  @impl true
  def placeholder(_index), do: "?"

  @impl true
  def quote_identifier(identifier) when is_binary(identifier) do
    escaped = String.replace(identifier, "\"", "\"\"")
    "\"#{escaped}\""
  end

  def quote_identifier(identifier), do: identifier |> to_string() |> quote_identifier()

  @impl true
  def supports?(feature) do
    feature in [:cte, :window_functions, :transactions]
  end

  @impl true
  def validate_connection(connection) do
    resolved_connection = resolve_connection(connection)

    cond do
      not dependency_available?() ->
        {:error, @missing_dependency}

      is_reference(resolved_connection) ->
        :ok

      true ->
        {:error, {:invalid_connection, connection}}
    end
  end

  @impl true
  def connection_info(connection) do
    resolved_connection = resolve_connection(connection)

    cond do
      is_reference(resolved_connection) ->
        %{type: :sqlite, connection: :exqlite, status: :connected}

      true ->
        %{type: :sqlite, status: :invalid, value: connection}
    end
  end

  @impl true
  def transaction(connection, fun, _opts \\ []) when is_function(fun, 1) do
    resolved_connection = resolve_connection(connection)

    with :ok <- validate_connection(resolved_connection),
         {:ok, _} <- execute(resolved_connection, "BEGIN", [], []) do
      execute_transaction_fun(resolved_connection, fun)
    end
  end

  defp execute_transaction_fun(connection, fun) do
    case fun.(connection) do
      {:error, reason} ->
        rollback(connection, reason)

      result ->
        case execute(connection, "COMMIT", [], []) do
          {:ok, _} -> {:ok, result}
          {:error, reason} -> rollback(connection, reason)
        end
    end
  rescue
    error ->
      rollback(connection, error)
  catch
    kind, reason ->
      rollback(connection, {kind, reason})
  end

  defp rollback(connection, reason) do
    _ = execute(connection, "ROLLBACK", [], [])
    {:error, reason}
  end

  defp execute_statement(connection, query, params) do
    case Exqlite.Sqlite3.prepare(connection, query) do
      {:ok, statement} ->
        result =
          with :ok <- bind_params(statement, params),
               {:ok, columns} <- Exqlite.Sqlite3.columns(connection, statement),
               {:ok, rows} <- Exqlite.Sqlite3.fetch_all(connection, statement) do
            {:ok,
             %{
               rows: rows || [],
               columns: Enum.map(columns || [], &to_string/1)
             }}
          end

        _ = Exqlite.Sqlite3.release(connection, statement)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bind_params(statement, params) do
    try do
      :ok = Exqlite.Sqlite3.bind(statement, params)
      :ok
    rescue
      error in ArgumentError -> {:error, {:invalid_query_params, Exception.message(error)}}
    end
  end

  defp resolve_connection(%{adapter: _adapter, connection: nested_connection}) do
    resolve_connection(nested_connection)
  end

  defp resolve_connection(%{db: db}) when is_reference(db), do: db
  defp resolve_connection(connection), do: connection

  defp normalize_query(query) when is_binary(query), do: query
  defp normalize_query(query), do: IO.iodata_to_binary(query)

  defp dependency_available? do
    Code.ensure_loaded?(Exqlite.Sqlite3) and function_exported?(Exqlite.Sqlite3, :open, 2) and
      function_exported?(Exqlite.Sqlite3, :prepare, 2) and
      function_exported?(Exqlite.Sqlite3, :bind, 2) and
      function_exported?(Exqlite.Sqlite3, :columns, 2) and
      function_exported?(Exqlite.Sqlite3, :fetch_all, 2) and
      function_exported?(Exqlite.Sqlite3, :release, 2)
  end
end
