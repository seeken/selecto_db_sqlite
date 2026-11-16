defmodule SelectoDBSQLite.QueryGuard do
  @moduledoc false
  alias SelectoDBSQLite.QueryGuardOwner

  def run(connection, operation) do
    with {:ok, prior} <- enable(connection) do
      try do
        operation.()
      after
        case restore(connection, prior) do
          :ok -> :ok
          _ -> raise "SQLite read-only state could not be restored"
        end
      end
    end
  end

  def enable(connection) do
    connection = unwrap(connection)

    with :ok <- SelectoDBSQLite.ConnectionOwner.acquire(connection) do
      case QueryGuardOwner.acquire(connection) do
        {:ok, _} = result ->
          result

        error ->
          SelectoDBSQLite.ConnectionOwner.release(connection)
          error
      end
    end
  end

  def restore(connection, prior) do
    connection = unwrap(connection)

    try do
      QueryGuardOwner.release(connection, prior)
    after
      SelectoDBSQLite.ConnectionOwner.release(connection)
    end
  end

  def close(connection), do: QueryGuardOwner.close(unwrap(connection))

  # Only the connection coordinator touches query_only while it owns a read.
  # It restores saved state before handing off, including when a consumer dies.
  def enable_native(connection) do
    with {:ok, statement} <- Exqlite.Sqlite3.prepare(connection, "PRAGMA query_only") do
      try do
        with {:row, [prior]} when prior in [0, 1] <- Exqlite.Sqlite3.step(connection, statement),
             :ok <- Exqlite.Sqlite3.execute(connection, "PRAGMA query_only = ON") do
          {:ok, prior}
        else
          _ -> {:error, :sqlite_read_only_state_unavailable}
        end
      after
        Exqlite.Sqlite3.release(connection, statement)
      end
    end
  rescue
    _ -> {:error, :sqlite_read_only_state_unavailable}
  end

  def restore_native(connection, prior) when prior in [0, 1] do
    Exqlite.Sqlite3.execute(connection, "PRAGMA query_only = #{prior}")
  rescue
    _ -> {:error, :sqlite_read_only_state_unavailable}
  end

  defp unwrap(%{connection: connection}), do: connection
  defp unwrap(connection), do: connection
end
