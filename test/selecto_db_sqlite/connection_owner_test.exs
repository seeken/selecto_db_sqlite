defmodule SelectoDBSQLite.ConnectionOwnerTest do
  use ExUnit.Case, async: false
  alias SelectoDBSQLite.Adapter

  setup do
    {:ok, connection} = Adapter.connect(database: ":memory:", temp_store: :memory)
    sql(connection, "CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT)")
    on_exit(fn -> Adapter.disconnect(connection) end)
    %{connection: connection}
  end

  test "raw BEGIN retains its process owner until rollback", %{connection: connection} do
    sql(connection, "BEGIN IMMEDIATE")
    sql(connection, "INSERT INTO items VALUES(1,'rolled back')")
    writer = Task.async(fn -> sql(connection, "INSERT INTO items VALUES(2,'committed')") end)
    early = Task.yield(writer, 50)
    sql(connection, "ROLLBACK")
    if is_nil(early), do: Task.await(writer)
    assert sql(connection, "SELECT * FROM items") == [[2, "committed"]]
    assert is_nil(early)
  end

  test "savepoint-only host retains owner through rollback-to and nested adapter transactions", %{
    connection: connection
  } do
    sql(connection, "SAVEPOINT host")

    assert {:ok, :nested} =
             Adapter.transaction(connection, fn conn ->
               sql(conn, "INSERT INTO items VALUES(1,'nested')")
               {:ok, :nested}
             end)

    writer = Task.async(fn -> sql(connection, "INSERT INTO items VALUES(2,'committed')") end)
    assert Task.yield(writer, 50) == nil
    sql(connection, "ROLLBACK TO host")
    assert Task.yield(writer, 50) == nil
    sql(connection, "RELEASE host")
    Task.await(writer)
    assert sql(connection, "SELECT * FROM items") == [[2, "committed"]]
  end

  test "comments and quoted savepoint names cannot release another process early", %{
    connection: connection
  } do
    sql(connection, "/* comment */ SAVEPOINT /* gap */ \"outer -- name\"")
    sql(connection, "SAVEPOINT 'inner''name'")
    writer = Task.async(fn -> sql(connection, "INSERT INTO items VALUES(2,'committed')") end)
    assert Task.yield(writer, 50) == nil
    sql(connection, "ROLLBACK/* gap */TRANSACTION/* gap */TO/* gap */SAVEPOINT \"outer -- name\"")
    assert Task.yield(writer, 50) == nil
    sql(connection, "RELEASE -- gap\n SAVEPOINT [outer -- name]")
    Task.await(writer)
    assert sql(connection, "SELECT * FROM items") == [[2, "committed"]]
  end

  test "dead transaction owner rolls back before handing off to a queued writer", %{
    connection: connection
  } do
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        Adapter.transaction(connection, fn conn ->
          sql(conn, "INSERT INTO items VALUES(1,'abandoned')")
          send(parent, :held)

          receive do
            :never -> :ok
          end
        end)
      end)

    assert_receive :held
    writer = Task.async(fn -> sql(connection, "INSERT INTO items VALUES(2,'committed')") end)
    assert Task.yield(writer, 50) == nil
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    Task.await(writer)
    assert sql(connection, "SELECT * FROM items") == [[2, "committed"]]
  end

  test "a queued process that dies does not take ownership", %{connection: connection} do
    sql(connection, "BEGIN")

    {waiter, monitor} =
      spawn_monitor(fn -> sql(connection, "INSERT INTO items VALUES(1,'dead')") end)

    Process.exit(waiter, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^waiter, :killed}
    sql(connection, "COMMIT")
    assert {:ok, :healthy} = Adapter.transaction(connection, fn _ -> {:ok, :healthy} end)
    assert sql(connection, "SELECT * FROM items") == []
  end

  defp sql(connection, text) do
    assert {:ok, %{rows: rows}} = Adapter.execute(connection, text, [], [])
    rows
  end
end
