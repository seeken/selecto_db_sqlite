defmodule SelectoDBSQLite.RowStream do
  @moduledoc false

  alias SelectoDBSQLite.Adapter

  # Validate and report columns without holding a live statement when the
  # caller never consumes the enumerable. Each enumeration owns a statement.
  def build(connection, query, params, opts) do
    timeout = Keyword.get(opts, :stream_timeout, Keyword.get(opts, :timeout, 30_000))

    if is_integer(timeout) and timeout >= 0 do
      with {:ok, statement} <- Exqlite.Sqlite3.prepare(connection, query) do
        result =
          try do
            with :ok <- Exqlite.Sqlite3.bind(statement, params),
                 {:ok, columns} <- Exqlite.Sqlite3.columns(connection, statement) do
              {:ok, row_stream(connection, query, params, timeout), columns}
            end
          after
            Exqlite.Sqlite3.release(connection, statement)
          end

        result
      end
    else
      {:error, {:invalid_stream_timeout, timeout}}
    end
  end

  defp row_stream(connection, query, params, timeout) do
    Stream.resource(
      fn ->
        case Exqlite.Sqlite3.prepare(connection, query) do
          {:ok, statement} ->
            try do
              case Exqlite.Sqlite3.bind(statement, params) do
                :ok -> {statement, System.monotonic_time(:millisecond) + timeout}
                {:error, reason} -> raise_error(reason)
              end
            rescue
              exception ->
                Exqlite.Sqlite3.release(connection, statement)
                reraise exception, __STACKTRACE__
            catch
              kind, reason ->
                Exqlite.Sqlite3.release(connection, statement)
                :erlang.raise(kind, reason, __STACKTRACE__)
            end

          {:error, reason} ->
            raise_error(reason)
        end
      end,
      fn {statement, deadline} = state ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)
        task = Task.async(fn -> Exqlite.Sqlite3.step(connection, statement) end)

        case Task.yield(task, remaining) do
          {:ok, {:row, row}} ->
            {[row], state}

          {:ok, :done} ->
            {:halt, state}

          {:ok, {:error, reason}} ->
            raise_error(reason)

          nil ->
            Exqlite.Sqlite3.interrupt(connection)
            Task.shutdown(task)

            raise Selecto.Error.to_exception(
                    Selecto.Error.timeout_error("SQLite stream timed out")
                  )
        end
      end,
      fn {statement, _deadline} -> Exqlite.Sqlite3.release(connection, statement) end
    )
  end

  defp raise_error(reason), do: raise(Selecto.Error.to_exception(Adapter.normalize_error(reason)))
end
