defmodule SelectoDBSQLite.TransactionOwnershipTest do
  use ExUnit.Case, async: false

  alias SelectoDBSQLite.Adapter
  alias Selecto.Write.{Command, Result, Error}

  setup do
    {:ok, connection} = Adapter.connect(database: ":memory:", temp_store: :memory)
    execute!(connection, "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
    on_exit(fn -> Adapter.disconnect(connection) end)
    %{connection: connection}
  end

  test "successful writes preserve caller-owned BEGIN and remain subject to caller rollback", %{
    connection: connection
  } do
    execute!(connection, "BEGIN")
    execute!(connection, "INSERT INTO items VALUES (1, 'caller')")

    command =
      command!(
        operation: :insert,
        relation: :items,
        assignments: [
          %{field: :id, value: {:literal, 2}},
          %{field: :name, value: {:literal, "adapter"}}
        ],
        returning: [:id]
      )

    assert {:ok, %Result{affected_rows: 1}} = Adapter.execute_write_unsafe(connection, command)
    assert rows(connection) == [[1, "caller"], [2, "adapter"]]
    execute!(connection, "ROLLBACK")
    assert rows(connection) == []
  end

  test "failed cardinality and nested callback failures roll back only their savepoints", %{
    connection: connection
  } do
    execute!(connection, "BEGIN IMMEDIATE")
    execute!(connection, "INSERT INTO items VALUES (1, 'caller'), (2, 'other')")

    command =
      command!(
        operation: :update,
        relation: :items,
        assignments: [%{field: :name, value: {:literal, "changed"}}],
        predicate: {:in, {:field, :id}, [1, 2]},
        expected_cardinality: {:exactly, 1},
        returning: :none
      )

    assert {:error, %Error{type: :cardinality_mismatch}} =
             Adapter.execute_write_unsafe(connection, command)

    assert rows(connection) == [[1, "caller"], [2, "other"]]

    assert {:ok, :outer} =
             Adapter.transaction(connection, fn conn ->
               execute!(conn, "UPDATE items SET name = 'outer' WHERE id = 1")

               assert {:error, :inner} =
                        Adapter.transaction(conn, fn nested ->
                          execute!(nested, "UPDATE items SET name = 'inner' WHERE id = 2")
                          {:error, :inner}
                        end)

               {:ok, :outer}
             end)

    assert rows(connection) == [[1, "outer"], [2, "other"]]
    execute!(connection, "COMMIT")
    assert rows(connection) == [[1, "outer"], [2, "other"]]
  end

  test "savepoint-only host transactions and exceptions preserve caller state", %{
    connection: connection
  } do
    execute!(connection, "SAVEPOINT selecto_sp_1")
    execute!(connection, "INSERT INTO items VALUES (1, 'caller')")

    assert {:error, {:transaction_exception, %RuntimeError{}}} =
             Adapter.transaction(connection, fn conn ->
               execute!(conn, "INSERT INTO items VALUES (2, 'adapter')")
               raise "fail inside adapter"
             end)

    assert rows(connection) == [[1, "caller"]]
    execute!(connection, "ROLLBACK TO SAVEPOINT selecto_sp_1")
    execute!(connection, "RELEASE SAVEPOINT selecto_sp_1")
    assert rows(connection) == []
  end

  defp execute!(connection, sql), do: assert({:ok, _} = Adapter.execute(connection, sql, [], []))

  defp rows(connection) do
    assert {:ok, %{rows: rows}} =
             Adapter.execute(connection, "SELECT id, name FROM items ORDER BY id", [], [])

    rows
  end

  defp command!(opts) do
    assert {:ok, command} = Command.new(Map.new(opts))
    command
  end
end
