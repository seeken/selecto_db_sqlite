defmodule SelectoDBSQLite.RowStream do
  @moduledoc false

  alias SelectoDBSQLite.Adapter

  # Validate and report columns without holding a live statement when the
  # caller never consumes the enumerable. Each enumeration owns a statement.
  def build(connection, query, params, opts) do
    timeout = Keyword.get(opts, :stream_timeout, Keyword.get(opts, :timeout, 30_000))

    if is_integer(timeout) and timeout >= 0 do
      SelectoDBSQLite.QueryGuard.run(connection, fn ->
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
      end)
    else
      {:error, {:invalid_stream_timeout, timeout}}
    end
  end

  defp row_stream(connection, query, params, timeout) do
    Stream.resource(
      fn ->
        {:ok, prior} = SelectoDBSQLite.QueryGuard.enable(connection)

        try do
          case Exqlite.Sqlite3.prepare(connection, query) do
            {:ok, statement} ->
              try do
                case Exqlite.Sqlite3.bind(statement, params) do
                  :ok -> {statement, System.monotonic_time(:millisecond) + timeout, prior}
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
        rescue
          refusal in Selecto.Error.Refused ->
            SelectoDBSQLite.QueryGuard.restore(connection, prior)
            reraise refusal, __STACKTRACE__

          # Raised by the driver (a parameter it cannot bind), as the
          # non-stream path raises it.
          exception ->
            SelectoDBSQLite.QueryGuard.restore(connection, prior)
            raise_error({:adapter_raised, exception})
        catch
          kind, reason ->
            SelectoDBSQLite.QueryGuard.restore(connection, prior)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end
      end,
      fn {statement, deadline, _prior} = state ->
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

            raise Selecto.Error.Refused, Selecto.Error.timeout_error("SQLite stream timed out")
        end
      end,
      fn {statement, _deadline, prior} ->
        try do
          Exqlite.Sqlite3.release(connection, statement)
        after
          case SelectoDBSQLite.QueryGuard.restore(connection, prior) do
            :ok ->
              :ok

            _ ->
              raise Selecto.Error.Refused,
                    Selecto.Error.connection_error("SQLite read-only state could not be restored")
          end
        end
      end
    )
  end

  # Raised while the stream is enumerated: the Selecto.Error the non-stream
  # path returns for the same failure, as Selecto.Error.Refused.
  defp raise_error(reason), do: Selecto.Error.raise_stream_failure!(Adapter, reason)
end
