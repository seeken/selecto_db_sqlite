defmodule SelectoDBSQLite.AdapterTest do
  use ExUnit.Case, async: false

  alias SelectoDBSQLite.Adapter

  setup do
    {:ok, connection} = Adapter.connect(database: ":memory:")

    assert {:ok, _result} =
             Adapter.execute(
               connection,
               "CREATE TABLE values_under_test (id INTEGER PRIMARY KEY, amount DECIMAL(12,2), active INTEGER)",
               [],
               []
             )

    assert {:ok, _result} =
             Adapter.execute(
               connection,
               "INSERT INTO values_under_test VALUES (1, 7.50, 0), (2, 12.50, 1), (3, 20.25, 1)",
               [],
               []
             )

    on_exit(fn -> Adapter.disconnect(connection) end)
    %{connection: connection}
  end

  test "binds Decimal values through SQLite's numeric affinity", %{connection: connection} do
    assert {:ok, %{rows: [[2], [3]]}} =
             Adapter.execute(
               connection,
               "SELECT id FROM values_under_test WHERE amount > ? ORDER BY id",
               [Decimal.new("10")],
               []
             )
  end

  test "binds Elixir booleans as SQLite integer booleans", %{connection: connection} do
    assert {:ok, %{rows: [[2], [3]]}} =
             Adapter.execute(
               connection,
               "SELECT id FROM values_under_test WHERE active = ? ORDER BY id",
               [true],
               []
             )

    assert {:ok, %{rows: [[1]]}} =
             Adapter.execute(
               connection,
               "SELECT id FROM values_under_test WHERE active = ? ORDER BY id",
               [false],
               []
             )
  end

  test "binds combined boolean and Decimal predicates", %{connection: connection} do
    assert {:ok, %{rows: [[3]]}} =
             Adapter.execute(
               connection,
               "SELECT id FROM values_under_test WHERE active = ? AND amount >= ? ORDER BY id",
               [true, Decimal.new("15")],
               []
             )
  end
end
