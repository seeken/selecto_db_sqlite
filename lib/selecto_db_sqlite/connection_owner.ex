defmodule SelectoDBSQLite.ConnectionOwner do
  @moduledoc false
  use GenServer

  # One monitored, reentrant lease spans each complete transaction, query guard
  # or raw BEGIN/SAVEPOINT. A per-process depth counter alone cannot establish
  # connection ownership. Callbacks still execute in their caller's process.
  def run(connection, operation) do
    with :ok <- acquire(connection) do
      try do
        operation.()
      after
        release(connection)
      end
    end
  end

  def acquire(connection) do
    with {:ok, owner} <- coordinator(connection) do
      GenServer.call(owner, {:acquire, self()}, :infinity)
    end
  end

  def release(connection), do: call(connection, {:release, self()})

  def statement(connection, sql, operation) do
    run(connection, fn ->
      result = operation.()
      if match?({:ok, _}, result), do: call(connection, {:statement, self(), sql})
      result
    end)
  end

  def close(connection) do
    case :global.whereis_name({__MODULE__, connection}) do
      :undefined -> :ok
      pid -> GenServer.stop(pid, :normal, :infinity)
    end
  end

  defp call(connection, message) do
    case :global.whereis_name({__MODULE__, connection}) do
      :undefined -> {:error, :sqlite_connection_owner_unavailable}
      pid -> GenServer.call(pid, message, :infinity)
    end
  end

  defp coordinator(connection) do
    case GenServer.start(__MODULE__, connection, name: {:global, {__MODULE__, connection}}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  @impl true
  def init(connection),
    do: {:ok, %{connection: connection, owner: nil, queue: :queue.new(), broken: false}}

  @impl true
  def handle_call({:acquire, _pid}, _from, %{broken: true} = state),
    do: {:reply, {:error, :sqlite_connection_state_unavailable}, state}

  def handle_call({:acquire, pid}, _from, %{owner: %{pid: pid} = owner} = state),
    do: {:reply, :ok, %{state | owner: %{owner | depth: owner.depth + 1}}}

  def handle_call({:acquire, pid}, _from, %{owner: nil} = state),
    do: {:reply, :ok, grant(state, pid)}

  def handle_call({:acquire, pid}, from, state),
    do: {:noreply, %{state | queue: :queue.in({pid, from}, state.queue)}}

  def handle_call({:release, pid}, _from, %{owner: %{pid: pid} = owner} = state) do
    state = %{state | owner: %{owner | depth: owner.depth - 1}}
    {:reply, :ok, maybe_handoff(state)}
  end

  def handle_call({:statement, pid, sql}, _from, %{owner: %{pid: pid} = owner} = state),
    do: {:reply, :ok, %{state | owner: track_boundary(owner, sql)}}

  def handle_call(_message, _from, state),
    do: {:reply, {:error, :sqlite_connection_owner_mismatch}, state}

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, pid, _reason},
        %{owner: %{pid: pid, monitor: monitor}} = state
      ) do
    {:noreply, handoff(recover(state))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.owner, do: recover(state)

    for {_pid, from} <- :queue.to_list(state.queue),
        do: GenServer.reply(from, {:error, :sqlite_connection_closed})

    :ok
  end

  defp grant(state, pid),
    do: %{
      state
      | owner: %{pid: pid, monitor: Process.monitor(pid), depth: 1, begun: false, savepoints: []}
    }

  defp maybe_handoff(%{owner: %{depth: 0, begun: false, savepoints: []} = owner} = state) do
    Process.demonitor(owner.monitor, [:flush])
    handoff(%{state | owner: nil})
  end

  defp maybe_handoff(state), do: state

  defp handoff(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, {pid, from}}, queue} ->
        state = %{state | queue: queue}

        cond do
          not Process.alive?(pid) ->
            handoff(state)

          state.broken ->
            GenServer.reply(from, {:error, :sqlite_connection_state_unavailable})
            handoff(state)

          true ->
            GenServer.reply(from, :ok)
            grant(state, pid)
        end
    end
  end

  defp recover(state) do
    Exqlite.Sqlite3.interrupt(state.connection)
    # Restore a dead reader's query_only state before rolling back or handing
    # the connection to a writer. Both coordinators monitor the same caller.
    SelectoDBSQLite.QueryGuard.close(state.connection)
    result = Exqlite.Sqlite3.execute(state.connection, "ROLLBACK")
    healthy = result == :ok or result == {:error, "cannot rollback - no transaction is active"}
    %{state | owner: nil, broken: not healthy}
  end

  # Track successful transaction control routed through the adapter. Preserve
  # quoted names and skip comments between tokens (not inside quoted names).
  # Direct Exqlite calls are trusted host seams and require host serialization.
  defp track_boundary(owner, sql) do
    tokens =
      Regex.scan(
        ~r/--[^\n]*(?:\n|$)|\/\*[\s\S]*?\*\/|"(?:[^"]|"")*"|'(?:[^']|'')*'|`(?:[^`]|``)*`|\[[^\]]*\]|[^\s;"'`\[\]\/-]+|[^\s;]/,
        sql
      )
      |> List.flatten()
      |> Enum.reject(&(String.starts_with?(&1, "--") or String.starts_with?(&1, "/*")))

    case tokens do
      [command | rest] -> track_command(owner, String.upcase(command, :ascii), rest)
      _ -> owner
    end
  end

  defp track_command(owner, "BEGIN", _), do: %{owner | begun: true}

  defp track_command(owner, command, _) when command in ["COMMIT", "END"],
    do: %{owner | begun: false, savepoints: []}

  defp track_command(owner, "SAVEPOINT", [name | _]),
    do: %{owner | savepoints: [savepoint_name(name) | owner.savepoints]}

  defp track_command(owner, "RELEASE", rest),
    do: release_savepoint(owner, optional_keyword(rest, "SAVEPOINT"))

  defp track_command(owner, "ROLLBACK", rest) do
    case optional_keyword(rest, "TRANSACTION") do
      [word | more] ->
        if String.upcase(word, :ascii) == "TO",
          do: rollback_to(owner, optional_keyword(more, "SAVEPOINT")),
          else: %{owner | begun: false, savepoints: []}

      [] ->
        %{owner | begun: false, savepoints: []}
    end
  end

  defp track_command(owner, _, _), do: owner

  defp optional_keyword([word | rest] = tokens, expected),
    do: if(String.upcase(word, :ascii) == expected, do: rest, else: tokens)

  defp optional_keyword([], _), do: []

  defp release_savepoint(owner, [name | _]) do
    remaining = Enum.drop_while(owner.savepoints, &(&1 != savepoint_name(name)))
    %{owner | savepoints: Enum.drop(remaining, 1)}
  end

  defp release_savepoint(owner, _), do: owner

  defp rollback_to(owner, [name | _]),
    do: %{owner | savepoints: Enum.drop_while(owner.savepoints, &(&1 != savepoint_name(name)))}

  defp rollback_to(owner, _), do: owner

  defp savepoint_name(name) do
    unquoted =
      case name do
        "\"" <> rest -> rest |> String.trim_trailing("\"") |> String.replace("\"\"", "\"")
        "'" <> rest -> rest |> String.trim_trailing("'") |> String.replace("''", "'")
        "`" <> rest -> rest |> String.trim_trailing("`") |> String.replace("``", "`")
        "[" <> rest -> String.trim_trailing(rest, "]")
        _ -> name
      end

    String.downcase(unquoted, :ascii)
  end
end
