defmodule SelectoDBSQLite.DocumentAggregateTest do
  use ExUnit.Case, async: true
  alias Selecto.Document.{Fixtures, ShapeRelease}
  alias Selecto.Query.{Plan, Result, Runtime}
  alias SelectoDBSQLite.{Adapter, DocumentQueryAdapter}

  @maximum 9_007_199_254_740_991
  @aggregates [
    %{"op" => "count", "as" => "total"},
    %{"op" => "sum", "as" => "priority_sum", "field" => "priority"},
    %{"op" => "min", "as" => "priority_min", "field" => "priority"},
    %{"op" => "max", "as" => "priority_max", "field" => "priority"}
  ]

  setup do
    {:ok, connection} = Adapter.connect(database: ":memory:")
    :ok = Exqlite.Sqlite3.execute(connection, "CREATE TABLE work_orders (document TEXT NOT NULL)")

    :ok =
      Exqlite.Sqlite3.execute(
        connection,
        "CREATE UNIQUE INDEX tenant_identity ON work_orders (json_extract(document, '$.\"tenant_id\"'), json_extract(document, '$.\"_id\"'))"
      )

    on_exit(fn -> Exqlite.Sqlite3.close(connection) end)
    %{connection: connection}
  end

  test "native totals match independent SQL and keep trusted tenant scope", %{connection: db} do
    for {id, value} <- [{"a", 7}, {"b", -3}, {"c", 0}, {"d", nil}] do
      insert(db, doc(id, value))
    end

    insert(db, Map.delete(doc("missing", 0), "priority"))
    insert(db, Map.put(doc("other-tenant", 999), "tenant_id", "tenant-b"))
    insert(db, Map.put(doc("array-tenant", 999), "tenant_id", ["tenant-a"]))
    plan = plan()
    assert {:ok, result} = Runtime.execute(plan, DocumentQueryAdapter, db)
    assert result.rows == [[5, 4, -3, 7]]
    assert result.next_cursor == nil

    assert {:ok, native} =
             Adapter.execute(
               db,
               "SELECT COUNT(*), SUM(json_extract(document, '$.priority')), MIN(json_extract(document, '$.priority')), MAX(json_extract(document, '$.priority')) FROM work_orders WHERE json_extract(document, '$.tenant_id') = ?",
               ["tenant-a"],
               []
             )

    assert result.rows == native.rows

    assert Result.to_maps(result) == [
             %{"total" => 5, "priority_sum" => 4, "priority_min" => -3, "priority_max" => 7}
           ]

    assert {:ok, compiled} = Runtime.compile(plan, DocumentQueryAdapter, db)
    assert compiled.artifact.sql =~ "SUM(CASE"
    assert compiled.artifact.sql =~ "AS MATERIALIZED"
    assert compiled.metadata["operation"] == "aggregate"

    assert {:ok, %{"indexed_search" => true}} =
             DocumentQueryAdapter.explain_query(db, compiled, [])
  end

  test "empty, all-null/missing, and zero are distinct", %{connection: db} do
    assert {:ok, %{rows: [[0, nil, nil, nil]]}} = run(db)
    insert(db, doc("null", nil))
    insert(db, Map.delete(doc("missing", 0), "priority"))
    assert {:ok, %{rows: [[2, nil, nil, nil]]}} = run(db)
    insert(db, doc("zero", 0))
    assert {:ok, %{rows: [[3, 0, 0, 0]]}} = run(db)
  end

  test "input bound rejects the sentinel instead of returning partial totals", %{connection: db} do
    insert(db, doc("a", 1))
    insert(db, doc("b", 2))
    assert {:ok, %{rows: [[2, 3, 1, 2]]}} = run(db, %{"bounds" => %{"max_input_rows" => 2}})
    assert {:error, _} = run(db, %{"bounds" => %{"max_input_rows" => 1}})
  end

  test "exact signed integers reject unsafe sum inputs without float coercion", %{connection: db} do
    bound = div(@maximum, 2)
    insert(db, doc("a", bound))
    insert(db, doc("b", -bound))
    assert {:ok, %{rows: [[2, 0, low, high]]}} = run(db, %{"bounds" => %{"max_input_rows" => 2}})
    assert low == -bound and high == bound
    clear(db)
    insert(db, doc("extreme", @maximum))

    assert {:ok, %{rows: [[1, @maximum, @maximum, @maximum]]}} =
             run(db, %{"bounds" => %{"max_input_rows" => 1}})

    assert {:error, _} = run(db, %{"bounds" => %{"max_input_rows" => 2}})

    assert {:ok, %{rows: [[@maximum, @maximum]]}} =
             run(db, %{"aggregate" => Enum.drop(@aggregates, 2)})

    clear(db)
    insert(db, doc("extreme", -@maximum))

    assert {:ok, %{rows: [[1, -@maximum, -@maximum, -@maximum]]}} =
             run(db, %{"bounds" => %{"max_input_rows" => 1}})
  end

  test "malformed matching documents are rejected even for count", %{connection: db} do
    for value <- [1.0, "1", true, [], %{}] do
      clear(db)
      insert(db, doc("invalid", value))
      assert {:error, _} = run(db)
      assert {:error, _} = run(db, %{"aggregate" => [hd(@aggregates)]})
    end

    for value <- [@maximum + 1, -@maximum - 1] do
      clear(db)
      insert(db, doc("numeric-bound", value))
      assert {:error, _} = run(db)
      assert {:ok, %{rows: [[1]]}} = run(db, %{"aggregate" => [hd(@aggregates)]})
    end

    clear(db)
    insert(db, Map.delete(doc("invalid", 1), "state"))
    assert {:error, _} = run(db)
  end

  test "filter parameters remain bound and nested field aliases export correctly", %{
    connection: db
  } do
    insert(db, doc("a", 7))
    value = "open' OR 1=1 --"
    query = plan(%{"where" => %{"field" => "state", "op" => "eq", "value" => value}})
    assert {:ok, compiled} = Runtime.compile(query, DocumentQueryAdapter, db)
    refute compiled.artifact.sql =~ value
    assert value in compiled.artifact.params
    assert {:ok, %{rows: [[0, nil, nil, nil]]}} = Runtime.execute(query, DocumentQueryAdapter, db)
    clear(db)

    shape =
      put_in(Fixtures.aggregate_shape(), ["shape", "fields", "priority", "path"], [
        "labor",
        "minutes"
      ])

    {:ok, release} = ShapeRelease.approve(shape, approved_by: "sqlite-test-author")
    insert(db, doc("nested", 7) |> Map.delete("priority") |> Map.put("labor", %{"minutes" => 7}))

    {:ok, query} =
      Plan.new(release, "work_orders", %{"aggregate" => @aggregates},
        trusted_context: %{tenant_id: "tenant-a"}
      )

    assert {:ok, result} = Runtime.execute(query, DocumentQueryAdapter, db)

    assert Jason.decode!(Jason.encode!(Result.to_maps(result))) == [
             %{"total" => 1, "priority_sum" => 7, "priority_min" => 7, "priority_max" => 7}
           ]
  end

  test "byte bounds, index evidence and compiled artifact integrity fail closed", %{
    connection: db
  } do
    insert(db, doc("a", 7))
    assert {:error, _} = run(db, %{"bounds" => %{"max_bytes" => 1}})
    assert {:ok, compiled} = Runtime.compile(plan(), DocumentQueryAdapter, db)
    tampered = put_in(compiled.artifact.sql, "SELECT 1")
    assert {:error, _} = DocumentQueryAdapter.execute_query(db, tampered, [])
    :ok = Exqlite.Sqlite3.execute(db, "DROP INDEX tenant_identity")
    assert {:error, _} = run(db)
  end

  test "parsed nested paths treat nonobject parents as missing", %{connection: db} do
    shape =
      put_in(Fixtures.aggregate_shape(), ["shape", "fields", "priority", "path"], [
        "labor",
        "minutes"
      ])

    {:ok, release} = ShapeRelease.approve(shape, approved_by: "sqlite-test-author")

    for {parent, index} <- Enum.with_index([[%{"minutes" => 3}], nil, 3, "text", true]) do
      document =
        doc("parent-#{index}", 0) |> Map.delete("priority") |> Map.put("labor", parent)

      assert :ok = ShapeRelease.validate_document(release, document)
      insert(db, document)
    end

    for where <- [nil, %{"field" => "priority", "op" => "missing"}] do
      query = %{"aggregate" => @aggregates, "where" => where}

      {:ok, plan} =
        Plan.new(release, "work_orders", query, trusted_context: %{tenant_id: "tenant-a"})

      assert {:ok, %{rows: [[5, nil, nil, nil]]}} =
               Runtime.execute(plan, DocumentQueryAdapter, db)
    end
  end

  defp run(db, overrides \\ %{}), do: Runtime.execute(plan(overrides), DocumentQueryAdapter, db)

  defp plan(overrides \\ %{}) do
    {:ok, plan} =
      Plan.new(
        Fixtures.aggregate_release(),
        "work_orders",
        Map.merge(%{"aggregate" => @aggregates}, overrides),
        trusted_context: %{tenant_id: "tenant-a"}
      )

    plan
  end

  defp doc(id, priority),
    do: Fixtures.work_orders() |> hd() |> Map.put("_id", id) |> Map.put("priority", priority)

  defp insert(db, document) do
    assert {:ok, _} =
             Adapter.execute(
               db,
               "INSERT INTO work_orders(document) VALUES (?)",
               [Jason.encode!(document)],
               []
             )
  end

  defp clear(db), do: Exqlite.Sqlite3.execute(db, "DELETE FROM work_orders")
end
