defmodule SelectoDBSQLite.QueryGuardOwner do
  @moduledoc false
  use GenServer
  alias SelectoDBSQLite.QueryGuard

  def acquire(connection) do
    with {:ok, owner} <- coordinator(connection) do
      GenServer.call(owner, {:acquire, self()}, :infinity)
    end
  end

  def release(connection, prior) do
    case :global.whereis_name({__MODULE__, connection}) do
      :undefined -> {:error, :sqlite_read_only_owner_unavailable}
      pid -> GenServer.call(pid, {:release, self(), prior}, :infinity)
    end
  end

  def close(connection) do
    case :global.whereis_name({__MODULE__, connection}) do
      :undefined -> :ok
      pid -> GenServer.stop(pid, :normal, :infinity)
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
    do: {:reply, {:error, :sqlite_read_only_state_unavailable}, state}

  def handle_call({:acquire, pid}, _from, %{owner: %{pid: pid} = owner} = state),
    do: {:reply, {:ok, 1}, %{state | owner: %{owner | depth: owner.depth + 1}}}

  def handle_call({:acquire, pid}, _from, %{owner: nil} = state) do
    {reply, state} = grant(state, pid)
    {:reply, reply, state}
  end

  def handle_call({:acquire, pid}, from, state),
    do: {:noreply, %{state | queue: :queue.in({pid, from}, state.queue)}}

  def handle_call({:release, pid, 1}, _from, %{owner: %{pid: pid, depth: depth} = owner} = state)
      when depth > 1,
      do: {:reply, :ok, %{state | owner: %{owner | depth: depth - 1}}}

  def handle_call(
        {:release, pid, prior},
        _from,
        %{owner: %{pid: pid, depth: 1, prior: prior} = owner} = state
      ) do
    Process.demonitor(owner.monitor, [:flush])
    result = QueryGuard.restore_native(state.connection, prior)
    {:reply, result, handoff(%{state | owner: nil, broken: result != :ok})}
  end

  def handle_call({:release, _pid, _prior}, _from, state),
    do: {:reply, {:error, :sqlite_read_only_owner_mismatch}, state}

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, pid, _reason},
        %{owner: %{pid: pid, monitor: monitor} = owner} = state
      ) do
    Exqlite.Sqlite3.interrupt(state.connection)
    result = QueryGuard.restore_native(state.connection, owner.prior)
    {:noreply, handoff(%{state | owner: nil, broken: result != :ok})}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.owner, do: QueryGuard.restore_native(state.connection, state.owner.prior)

    :queue.to_list(state.queue)
    |> Enum.each(fn {_pid, from} ->
      GenServer.reply(from, {:error, :sqlite_connection_closed})
    end)

    :ok
  end

  defp grant(state, pid) do
    case QueryGuard.enable_native(state.connection) do
      {:ok, prior} = success ->
        owner = %{pid: pid, monitor: Process.monitor(pid), prior: prior, depth: 1}
        {success, %{state | owner: owner}}

      error ->
        {error, state}
    end
  end

  defp handoff(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, {_pid, from}}, queue} when state.broken ->
        GenServer.reply(from, {:error, :sqlite_read_only_state_unavailable})
        handoff(%{state | queue: queue})

      {{:value, {pid, from}}, queue} ->
        {reply, next} = grant(%{state | queue: queue}, pid)
        GenServer.reply(from, reply)
        if next.owner, do: next, else: handoff(next)
    end
  end
end
