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

  test "primitive root array exception preserves recursive shape and scalar types", %{
    connection: connection
  } do
    assert Adapter.supports?(connection, :json_contains)

    samples = [
      {~s(["foo","bar"]), "bar", 1},
      {~s("bar"), ["bar"], 0},
      {~s([1,true,null]), true, 1},
      {~s([1]), true, 0},
      {~s([true]), 1, 0},
      {~s([null]), nil, 1},
      {~s([]), nil, 0},
      {~s([["bar"]]), "bar", 0},
      {~s([["bar"]]), ["bar"], 0},
      {~s({"a":["bar"]}), %{"a" => "bar"}, 0},
      {~s([{"a":1}]), %{"a" => 1}, 0}
    ]

    for {source, needle, expected} <- samples do
      assert contains(connection, source, needle) == expected
    end
  end

  test "public JSON filters admit primitives and arrays with native bound execution", %{
    connection: connection
  } do
    assert {:ok, _} =
             Adapter.execute(
               connection,
               "INSERT INTO documents VALUES (1, ?), (2, ?), (3, ?)",
               [~s(["foo","bar"]), ~s([["bar"]]), ~s({"a":1,"a":2})],
               []
             )

    domain = %{
      name: "Documents",
      source: %{
        source_table: "documents",
        primary_key: :id,
        fields: [:id, :payload],
        columns: %{id: %{type: :integer}, payload: %{type: :jsonb}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    for {needle, expected} <- [
          {"bar", [[1]]},
          {["bar"], [[1]]},
          {%{"a" => 1}, []},
          {%{"a" => 2}, [[3]]}
        ] do
      query =
        domain
        |> Selecto.configure(connection, adapter: Adapter)
        |> Selecto.select(["id"])
        |> Selecto.filter({"payload", {:json_contains, needle}})
        |> Selecto.order_by(["id"])

      {sql, params} = Selecto.to_sql(query)
      assert {:ok, %{rows: ^expected}} = Adapter.execute(connection, sql, params, [])
      assert needle != "bar" or "bar" in params
    end
  end

  test "duplicate object keys use only the last value at each nesting level", %{
    connection: connection
  } do
    for {source, needle, expected} <- [
          {~s({"a":1,"a":2}), %{"a" => 1}, 0},
          {~s({"a":1,"a":2}), %{"a" => 2}, 1},
          {~s({"a":null,"a":true}), %{"a" => nil}, 0},
          {~s({"a":true,"a":null}), %{"a" => nil}, 1},
          {~s({"a":{"x":1,"x":2}}), %{"a" => %{"x" => 1}}, 0},
          {~s({"a":{"x":1,"x":2}}), %{"a" => %{"x" => 2}}, 1},
          {~s({"a":{"x":1},"a":{"y":2}}), %{"a" => %{"x" => 1}}, 0},
          {~s({"a":{"x":1},"a":{"y":2}}), %{"a" => %{"y" => 2}}, 1},
          {~s({"A":1,"a":2,"A":3}), %{"A" => 1}, 0},
          {~s({"A":1,"a":2,"A":3}), %{"A" => 3, "a" => 2}, 1}
        ] do
      assert contains(connection, source, needle) == expected
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
