defmodule SelectoDBSQLite.PlaceholderConversionTest do
  use ExUnit.Case, async: true

  alias SelectoDBSQLite.Adapter

  setup do
    {:ok, connection} = Adapter.connect(database: ":memory:")
    on_exit(fn -> Exqlite.Sqlite3.close(connection) end)
    %{connection: connection}
  end

  test "numbered placeholders are rewritten by their full number", %{connection: connection} do
    params = Enum.to_list(101..111)
    sql = "SELECT " <> Enum.map_join(1..11, ", ", &"$#{&1}")

    assert {:ok, %{rows: [row]}} = Adapter.execute(connection, sql, params, [])
    assert row == params
  end

  test "parameters bind by number, not by position", %{connection: connection} do
    assert {:ok, %{rows: [["second", "first", "second"]]}} =
             Adapter.execute(connection, "SELECT $2, $1, $2", ["first", "second"], [])
  end

  test "dollar-number text inside literals, identifiers and comments is not rewritten", %{
    connection: connection
  } do
    sql =
      "SELECT 'costs $1' AS label, $1 AS \"col$1\", $1 AS [b$1], $1 AS `t$1` " <>
        "/* $1 */ -- $1"

    assert {:ok, %{rows: [["costs $1", 5, 5, 5]], columns: ["label", "col$1", "b$1", "t$1"]}} =
             Adapter.execute(connection, sql, [5], [])

    assert {:ok, %{rows: [["it''s $1", 9]]}} =
             Adapter.execute(connection, "SELECT 'it''''s $1', $1", [9], [])
  end

  test "mixed or unmatched placeholders fail closed", %{connection: connection} do
    assert {:error, %Selecto.Error{type: :validation_error}} =
             Adapter.execute(connection, "SELECT $1, ?", [1, 2], [])

    assert {:error, %Selecto.Error{type: :validation_error}} =
             Adapter.execute(connection, "SELECT $3", [1, 2], [])
  end

  test "core-generated positional SQL passes through unchanged" do
    assert Adapter.convert_parameters("SELECT ? WHERE 'x$1' = ?", [1, 2]) ==
             {:ok, "SELECT ? WHERE 'x$1' = ?", [1, 2]}

    assert Adapter.convert_parameters("SELECT $2, a$1, $1", [:a, :b]) ==
             {:ok, "SELECT ?2, a$1, ?1", [:a, :b]}
  end
end
