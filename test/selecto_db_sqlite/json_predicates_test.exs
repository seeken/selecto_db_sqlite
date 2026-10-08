defmodule SelectoDBSQLite.JsonPredicatesTest do
  use ExUnit.Case, async: false

  alias Selecto.Dialect.Json.{Contains, ArrayContains, ArrayContainsAll}
  alias SelectoDBSQLite.{Adapter, Dialect}

  setup do
    {:ok, connection} = Adapter.connect(database: ":memory:")

    {:ok, _} =
      Adapter.execute(
        connection,
        "CREATE TABLE documents (id INTEGER PRIMARY KEY, body TEXT)",
        [],
        []
      )

    on_exit(fn -> Adapter.disconnect(connection) end)
    %{connection: connection}
  end

  test "object containment distinguishes missing, null, boolean, numeric and text", context do
    documents = [
      %{},
      %{"a" => nil},
      %{"a" => true},
      %{"a" => false},
      %{"a" => 1},
      %{"a" => 0},
      %{"a" => 1.0},
      %{"a" => "1"},
      %{"a" => %{}},
      []
    ]

    seed(context.connection, documents)

    for {value, expected} <- [
          {nil, [2]},
          {true, [3]},
          {false, [4]},
          {1, [5, 7]},
          {0, [6]},
          {"1", [8]}
        ] do
      assert contains(context.connection, %{"a" => value}) == expected
    end

    assert contains(context.connection, %{}) == Enum.to_list(1..9)
    assert contains(context.connection, %{"a" => %{}}) == [9]
  end

  test "nested object comparisons retain empty-object type requirements and safe key labels",
       context do
    seed(context.connection, [
      %{"a" => %{"b" => %{}}},
      %{"a" => %{"b" => nil}},
      %{"a" => %{}},
      %{"a" => []},
      %{"a" => %{"b" => %{"c" => 1}}},
      %{"0" => %{"a.b" => "O'Brien"}},
      [%{"a.b" => "O'Brien"}]
    ])

    assert contains(context.connection, %{"a" => %{"b" => %{}}}) == [1, 5]
    assert contains(context.connection, %{"0" => %{"a.b" => "O'Brien"}}) == [6]

    assert contains(context.connection, %{"a" => []}) == [4]
    assert contains(context.connection, %{"a" => %{"bad" => [[1]]}}) == []
  end

  test "malformed documents and SQL null do not throw or satisfy containment", context do
    {:ok, _} =
      Adapter.execute(
        context.connection,
        "INSERT INTO documents VALUES (1, NULL), (2, 'not json'), (3, '{}'), (4, 'null')",
        [],
        []
      )

    assert contains(context.connection, %{}) == [3]
    assert contains(context.connection, %{"a" => nil}) == []
  end

  test "JSON extraction uses text booleans, casts and guarded malformed input", context do
    seed(context.connection, [%{"a" => true}, %{"a" => false}, %{"a" => nil}, %{"a" => 1}, %{}])

    {:ok, extraction} =
      Dialect.render_json_extraction(
        %Selecto.Dialect.Json.Extraction{column: "body", path: ["a"], as_text: true},
        %{}
      )

    {sql, params} =
      Selecto.SQL.Params.finalize(["SELECT ", extraction, " FROM documents ORDER BY id"],
        adapter: Adapter
      )

    assert {:ok, %{rows: [["true"], ["false"], [nil], ["1"], [nil]]}} =
             Adapter.execute(context.connection, sql, params, [])

    {:ok, _} =
      Adapter.execute(
        context.connection,
        "INSERT INTO documents VALUES (6, 'not json'), (7, NULL)",
        [],
        []
      )

    {:ok, exists} =
      Dialect.render_json_key_exists(
        %Selecto.Dialect.Json.KeyExists{column: "body", path: ["a"]},
        %{}
      )

    {sql, params} =
      Selecto.SQL.Params.finalize(["SELECT ", exists, " FROM documents ORDER BY id"],
        adapter: Adapter
      )

    assert {:ok, %{rows: [[1], [1], [1], [1], [0], [0], [nil]]}} =
             Adapter.execute(context.connection, sql, params, [])
  end

  test "array membership compares typed scalars and rejects non-array paths", context do
    seed(context.connection, [
      %{"a" => [nil, true, false, 1, "one"]},
      %{"a" => [1, 0]},
      %{"a" => [true]},
      %{"a" => [nil]},
      %{"a" => "one"},
      %{"a" => %{value: "one"}},
      %{},
      %{"a" => []},
      %{"a" => [1.0]},
      %{"a" => "1"}
    ])

    for {value, expected} <- [
          {nil, [1, 4]},
          {true, [1, 3]},
          {false, [1]},
          {1, [1, 2, 9]},
          {"one", [1]}
        ] do
      assert any(context.connection, value) == expected
    end

    assert any(context.connection, []) == []
    assert all(context.connection, []) == [1, 2, 3, 4, 8, 9]
    assert any(context.connection, [true, nil]) == [1, 3, 4]
    assert all(context.connection, [true, nil]) == [1]
    assert all(context.connection, [1, 1]) == [1, 2, 9]

    assert {:error, %Selecto.Error{type: :validation_error}} =
             Dialect.render_json_array_contains(
               %ArrayContains{column: "body", path: ["a"], value: [[1]]},
               %{}
             )

    assert {:error, %Selecto.Error{type: :validation_error}} =
             Dialect.render_json_array_contains_all(
               %ArrayContainsAll{column: "body", path: ["a"], values: [%{}]},
               %{}
             )
  end

  test "ordinary governed query compiles bound JSON comparisons", context do
    seed(context.connection, [%{"a" => true}, %{"a" => 1}, %{"a" => nil}, %{}])

    query =
      Selecto.configure(
        %{
          name: "documents",
          source: %{
            source_table: "documents",
            primary_key: :id,
            fields: [:id, :body],
            columns: %{id: %{type: :integer}, body: %{type: :jsonb}},
            associations: %{}
          },
          schemas: %{},
          joins: %{}
        },
        context.connection,
        adapter: Adapter
      )
      |> Selecto.select(["id"])
      |> Selecto.filter({"body", {:json_contains, %{"a" => true}}})

    {sql, params} = Selecto.to_sql(query)
    assert {:ok, %{rows: [[1]]}} = Adapter.execute(context.connection, sql, params, [])
  end

  defp seed(connection, documents) do
    documents
    |> Enum.with_index(1)
    |> Enum.each(fn {document, id} ->
      assert {:ok, _} =
               Adapter.execute(
                 connection,
                 "INSERT INTO documents VALUES (?, ?)",
                 [id, Jason.encode!(document)],
                 []
               )
    end)
  end

  defp contains(connection, value),
    do:
      run(
        connection,
        Dialect.render_json_contains(%Contains{column: "body", value: value}, %{})
      )

  defp any(connection, value),
    do:
      run(
        connection,
        Dialect.render_json_array_contains(
          %ArrayContains{column: "body", path: ["a"], value: value},
          %{}
        )
      )

  defp all(connection, values),
    do:
      run(
        connection,
        Dialect.render_json_array_contains_all(
          %ArrayContainsAll{column: "body", path: ["a"], values: values},
          %{}
        )
      )

  defp run(connection, {:ok, predicate}) do
    {sql, params} =
      Selecto.SQL.Params.finalize(["SELECT id FROM documents WHERE ", predicate, " ORDER BY id"],
        adapter: Adapter
      )

    assert {:ok, %{rows: rows}} = Adapter.execute(connection, sql, params, [])
    List.flatten(rows)
  end
end
