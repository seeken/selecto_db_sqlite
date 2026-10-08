defmodule SelectoDBSQLite.JsonContainmentTest do
  use ExUnit.Case, async: true

  alias SelectoDBSQLite.{Adapter, JsonContainment}

  setup do
    {:ok, connection} = Adapter.connect(database: ":memory:")
    on_exit(fn -> Adapter.disconnect(connection) end)

    {:ok, _} =
      Adapter.execute(
        connection,
        "CREATE TABLE documents (id INTEGER PRIMARY KEY, payload TEXT COLLATE NOCASE)",
        [],
        []
      )

    %{connection: connection}
  end

  test "nested objects and arrays match subsets without losing JSON types", %{
    connection: connection
  } do
    samples = [
      {%{"items" => [%{"a" => 1, "b" => [true, nil]}, %{"a" => 2}]},
       %{"items" => [%{"a" => 1, "b" => [nil, true]}]}, 1},
      {%{"items" => [%{"a" => 1}]}, %{"items" => [%{"a" => 1, "missing" => nil}]}, 0},
      {%{"items" => [1, true, "1", nil]}, %{"items" => [true, "1", nil, true]}, 1},
      {%{"items" => [1]}, %{"items" => [true]}, 0},
      {%{"items" => [true]}, %{"items" => [1]}, 0},
      {%{"items" => [1]}, %{"items" => ["1"]}, 0},
      {%{"a" => nil}, %{"a" => nil}, 1},
      {%{}, %{"a" => nil}, 0},
      {%{"a" => %{}}, %{"a" => %{}}, 1},
      {%{"a" => []}, %{"a" => %{}}, 0},
      {%{"a" => []}, %{"a" => []}, 1},
      {%{"a" => %{}}, %{"a" => []}, 0},
      {[%{"a" => 1, "b" => 2}], [%{"a" => 1}], 1},
      {[1, 2], [2, 2], 1},
      {[], [], 1},
      {[], %{}, 0},
      {1, 1.0, 1},
      {true, 1, 0},
      {"Ada", "ada", 0},
      {%{"A" => 1}, %{"a" => 1}, 0},
      {"text", %{"a" => 1}, 0},
      {"text", [1], 0},
      {%{"items" => ["text", %{"a" => 1}]}, %{"items" => [%{"a" => 1}]}, 1},
      {%{"items" => "text"}, %{"items" => [%{"a" => 1}]}, 0}
    ]

    for {source, needle, expected} <- samples do
      assert contains(connection, Jason.encode!(source), needle) == expected,
             "#{inspect(source)} contains #{inspect(needle)}"
    end
  end

  test "bound keys preserve quotes backslashes apostrophes and embedded NUL", %{
    connection: connection
  } do
    keys = ["a\"b", "a\\b", "O'Brien", "a.b[0]", "a\0b", "x') OR 1=1 --", "東京"]

    for key <- keys do
      assert contains(connection, Jason.encode!(%{key => %{"v" => "text"}}), %{
               key => %{"v" => "text"}
             }) == 1

      assert contains(connection, "{}", %{key => %{"v" => "text"}}) == 0
    end
  end

  test "SQL null stays null and malformed source JSON fails without a parser error", %{
    connection: connection
  } do
    assert contains(connection, nil, %{}) == nil
    assert contains(connection, "invalid", %{}) == 0
    assert contains(connection, Jason.encode!(nil), nil) == 1
    assert contains(connection, Jason.encode!(false), nil) == 0
  end

  defp contains(connection, source, needle) do
    {:ok, _} = Adapter.execute(connection, "DELETE FROM documents", [], [])
    {:ok, _} = Adapter.execute(connection, "INSERT INTO documents VALUES (1, ?)", [source], [])
    {:ok, fragment} = JsonContainment.render("payload", needle)

    {sql, params} =
      Selecto.SQL.Params.finalize(["SELECT ", fragment, " FROM documents"], adapter: Adapter)

    {:ok, %{rows: [[value]]}} = Adapter.execute(connection, sql, params, [])
    value
  end
end
