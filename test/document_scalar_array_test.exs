defmodule SelectoDBSQLite.DocumentScalarArrayTest do
  use ExUnit.Case, async: true
  alias Selecto.Document.{Fixtures, Missing, ShapeRelease}
  alias Selecto.Query.{Plan, Runtime}
  alias SelectoDBSQLite.{Adapter, DocumentQueryAdapter}

  @secret String.duplicate("scalar-array-control", 2)
  @maximum 9_007_199_254_740_991

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:")
    :ok = Exqlite.Sqlite3.execute(db, "CREATE TABLE work_orders (document TEXT NOT NULL)")

    :ok =
      Exqlite.Sqlite3.execute(
        db,
        "CREATE UNIQUE INDEX tenant_identity ON work_orders (json_extract(document, '$.\"tenant_id\"'), json_extract(document, '$.\"_id\"'))"
      )

    on_exit(fn -> Exqlite.Sqlite3.close(db) end)
    %{db: db, release: release()}
  end

  test "set membership preserves duplicates, empty arrays and binary strings", %{
    db: db,
    release: rel
  } do
    cases = [
      {"a", ["urgent", "urgent"]},
      {"b", ["routine", "urgent"]},
      {"c", []},
      {"d", ["café"]},
      {"e", ["CAFÉ"]}
    ]

    for {id, tags} <- cases, do: insert(db, doc(id, "tags", tags))

    for {op, value, expected} <- [
          {"contains", "urgent", ["a", "b"]},
          {"contains_any", ["routine", "café"], ["b", "d"]},
          {"contains_all", ["urgent", "routine", "urgent"], ["b"]},
          {"contains_any", [], []},
          {"contains_all", [], ["a", "b", "c", "d", "e"]}
        ] do
      assert ids(db, rel, member("tags", op, value)) == expected
    end

    assert {:ok, native} =
             Adapter.execute(
               db,
               "SELECT json_extract(document, '$._id') FROM work_orders WHERE EXISTS (SELECT 1 FROM json_each(document, '$.tags') AS tag WHERE tag.value = ?) ORDER BY json_extract(document, '$._id')",
               ["urgent"],
               []
             )

    assert native.rows == Enum.map(ids(db, rel, member("tags", "contains", "urgent")), &[&1])
  end

  test "invalid or absent arrays never match even contains_all empty", %{db: db, release: rel} do
    for {value, index} <-
          Enum.with_index([
            nil,
            7,
            "urgent",
            %{},
            [nil],
            ["urgent", 1],
            [["urgent"]],
            List.duplicate("urgent", 5)
          ]) do
      insert(db, doc("invalid-#{index}", "tags", value))
    end

    insert(db, Map.delete(doc("missing", "tags", []), "tags"))

    for {op, value} <- [
          {"contains", "urgent"},
          {"contains_any", ["urgent"]},
          {"contains_all", []}
        ] do
      assert ids(db, rel, member("tags", op, value)) == []
    end
  end

  test "an OR branch or an unfiltered aggregate still rejects selected invalid shapes", %{
    db: db,
    release: rel
  } do
    insert(db, doc("mixed", "tags", ["urgent", 1]))

    where = %{
      "op" => "or",
      "args" => [
        member("tags", "contains", "urgent"),
        %{"field" => "state", "op" => "eq", "value" => "open"}
      ]
    }

    assert {:error, _} = execute(db, rel, %{"where" => where})
    count = %{"aggregate" => [%{"op" => "count", "as" => "total"}]}
    assert {:error, _} = execute(db, rel, count)

    assert {:ok, %{rows: [[0]]}} =
             execute(db, rel, Map.put(count, "where", member("tags", "contains", "urgent")))
  end

  test "integer and boolean membership reject native numeric coercion", %{db: db, release: rel} do
    for {value, index} <-
          Enum.with_index([
            [1],
            [1.0],
            [true],
            [@maximum],
            [@maximum + 1],
            [-@maximum],
            [-@maximum - 1]
          ]) do
      insert(db, doc("number-#{index}", "ratings", value))
    end

    assert ids(db, rel, member("ratings", "contains", 1)) == ["number-0"]
    assert ids(db, rel, member("ratings", "contains", @maximum)) == ["number-3"]
    assert ids(db, rel, member("ratings", "contains", -@maximum)) == ["number-5"]
    clear(db)

    for {value, index} <- Enum.with_index([[true], [1], [false], [0], [true, 1]]) do
      insert(db, doc("bool-#{index}", "flags", value))
    end

    assert ids(db, rel, member("flags", "contains", true)) == ["bool-0"]
    assert ids(db, rel, member("flags", "contains", false)) == ["bool-2"]
  end

  test "native bound guards inspect the complete array and respect string byte limits", %{
    db: db,
    release: rel
  } do
    insert(db, doc("exact", "tags", List.duplicate("urgent", 4)))
    insert(db, doc("over", "tags", List.duplicate("urgent", 5)))
    assert ids(db, rel, member("tags", "contains", "urgent")) == ["exact"]
    clear(db)
    edge = String.duplicate("é", 8192)
    insert(db, doc("exact", "tags", [edge]))
    insert(db, doc("over", "tags", [edge <> "x"]))
    assert ids(db, rel, member("tags", "contains", edge)) == ["exact"]
    assert ids(db, rel, member("tags", "contains_all", [])) == ["exact"]
  end

  test "nested paths preserve missing parents and explicit projection preserves arrays", %{db: db} do
    shape = put_in(shape(), ["shape", "fields", "tags", "path"], ["details", "tags"])
    {:ok, rel} = ShapeRelease.approve(shape, approved_by: "sqlite-array-test")

    for {parent, index} <-
          Enum.with_index([
            [%{"tags" => ["urgent"]}],
            nil,
            "scalar",
            %{},
            %{"tags" => ["urgent"]}
          ]) do
      insert(db, doc("nested-#{index}", "details", parent) |> Map.delete("tags"))
    end

    assert ids(db, rel, member("tags", "contains", "urgent")) == ["nested-4"]
    assert {:ok, result} = execute(db, rel, %{"select" => ["id", "tags"]})

    assert result.rows == [
             ["nested-0", %Missing{}],
             ["nested-1", %Missing{}],
             ["nested-2", %Missing{}],
             ["nested-3", %Missing{}],
             ["nested-4", ["urgent"]]
           ]
  end

  test "tenant-bound cursors preserve membership and reject changed operands", %{
    db: db,
    release: rel
  } do
    for id <- ["a", "b"], do: insert(db, doc(id, "tags", ["urgent"]))
    insert(db, doc("other", "tags", ["urgent"]) |> Map.put("tenant_id", "tenant-b"))
    where = member("tags", "contains", "urgent")
    query = %{"select" => ["id"], "where" => where, "limit" => 1}
    assert {:ok, first} = execute(db, rel, query)
    assert first.rows == [["a"]]
    assert {:ok, second} = execute(db, rel, Map.put(query, "cursor", first.next_cursor))
    assert second.rows == [["b"]]
    assert second.next_cursor == nil

    assert {:error, _} =
             Plan.new(
               rel,
               "work_orders",
               Map.merge(query, %{
                 "where" => member("tags", "contains", "routine"),
                 "cursor" => first.next_cursor
               }),
               trusted_context: %{tenant_id: "tenant-a"},
               cursor_secret: @secret
             )
  end

  test "values are bound, indexed root search remains enforced and native tampering fails", %{
    db: db,
    release: rel
  } do
    value = "x' OR 1=1 --"
    insert(db, doc("injection", "tags", [value]))
    query = plan(rel, %{"where" => member("tags", "contains", value)})
    assert {:ok, compiled} = Runtime.compile(query, DocumentQueryAdapter, db)
    refute compiled.artifact.sql =~ value
    assert Jason.encode!([value]) in compiled.artifact.params
    assert {:ok, %{rows: [["injection"]]}} = Runtime.execute(query, DocumentQueryAdapter, db)

    assert {:ok, %{"indexed_search" => true, "unindexed_sort" => false}} =
             DocumentQueryAdapter.explain_query(db, compiled, [])

    assert {:error, _} =
             DocumentQueryAdapter.execute_query(db, put_in(compiled.artifact.sql, "SELECT 1"), [])

    :ok = Exqlite.Sqlite3.execute(db, "DROP INDEX tenant_identity")
    assert {:error, _} = Runtime.execute(query, DocumentQueryAdapter, db)
  end

  test "the shared native corpus has identical truth across scalar types", %{db: db} do
    rel = Fixtures.scalar_array_release()

    for {type, field} <- [{"string", "tags"}, {"integer", "ratings"}, {"boolean", "flags"}] do
      clear(db)
      corpus = Fixtures.scalar_array_cases(type)

      for entry <- corpus["cases"] do
        document =
          case entry.value do
            %Missing{} -> Map.delete(doc(entry.id, field, []), field)
            value -> doc(entry.id, field, value)
          end

        assert {:ok, _} = insert(db, document)
      end

      for {op, index} <- Enum.with_index(~w(contains contains_any contains_all)) do
        actual = ids(db, rel, member(field, op, corpus[op]))

        for entry <- corpus["cases"] do
          assert entry.id in actual == Enum.at(entry.expected, index),
                 "#{type}/#{entry.id}/#{op}"
        end
      end
    end
  end

  test "native byte validation rejects malformed UTF-8 without treating it as a valid empty operand match",
       %{db: db, release: rel} do
    valid = [
      "",
      <<0>>,
      <<0x7F>>,
      "é😀",
      <<0xC2, 0x80>>,
      <<0xDF, 0xBF>>,
      <<0xE0, 0xA0, 0x80>>,
      <<0xED, 0x9F, 0xBF>>,
      <<0xEE, 0x80, 0x80>>,
      <<0xF0, 0x90, 0x80, 0x80>>,
      <<0xF4, 0x8F, 0xBF, 0xBF>>
    ]

    invalid = [
      <<0xFF>>,
      <<0x80>>,
      <<0xC0, 0x80>>,
      <<0xC1, 0xBF>>,
      <<0xC2>>,
      <<0xE0, 0x80, 0x80>>,
      <<0xE2, 0x82>>,
      <<0xED, 0xA0, 0x80>>,
      <<0xED, 0xBF, 0xBF>>,
      <<0xF0, 0x80, 0x80, 0x80>>,
      <<0xF4, 0x90, 0x80, 0x80>>,
      <<0xF5, 0x80, 0x80, 0x80>>,
      <<0xF0, 0x90, 0x80>>
    ]

    for {value, index} <- Enum.with_index(valid ++ invalid) do
      id = "utf8-#{String.pad_leading(Integer.to_string(index), 2, "0")}"
      assert {:ok, _} = insert(db, doc(id, "tags", []))

      assert {:ok, _} =
               Adapter.execute(
                 db,
                 "UPDATE work_orders SET document = json_set(document, '$.tags', json_array('urgent', CAST(? AS TEXT))) WHERE json_extract(document, '$._id') = ?",
                 [value, id],
                 []
               )
    end

    expected =
      for index <- 0..(length(valid) - 1),
          do: "utf8-#{String.pad_leading(Integer.to_string(index), 2, "0")}"

    assert ids(db, rel, member("tags", "contains_all", [])) == expected
    assert ids(db, rel, member("tags", "contains", "urgent")) == expected
  end

  defp shape do
    Fixtures.scalar_array_shape()
    |> put_in(["shape", "fields", "tags", "scalar_array", "max_elements"], 4)
    |> put_in(["relations", "work_orders", "aggregate_ops"], ["count"])
  end

  defp release do
    {:ok, release} = ShapeRelease.approve(shape(), approved_by: "sqlite-array-test")
    release
  end

  defp member(field, op, value), do: %{"field" => field, "op" => op, "value" => value}

  defp doc(id, field, value),
    do: Fixtures.work_orders() |> hd() |> Map.put("_id", id) |> Map.put(field, value)

  defp plan(release, query) do
    query =
      if Map.has_key?(query, "aggregate"), do: query, else: Map.put_new(query, "select", ["id"])

    {:ok, plan} =
      Plan.new(release, "work_orders", query,
        trusted_context: %{tenant_id: "tenant-a"},
        cursor_secret: @secret
      )

    plan
  end

  defp execute(db, release, query),
    do: Runtime.execute(plan(release, query), DocumentQueryAdapter, db, cursor_secret: @secret)

  defp ids(db, release, where) do
    assert {:ok, result} = execute(db, release, %{"where" => where})
    List.flatten(result.rows)
  end

  defp insert(db, document),
    do:
      Adapter.execute(
        db,
        "INSERT INTO work_orders(document) VALUES (?)",
        [Jason.encode!(document)],
        []
      )

  defp clear(db), do: Exqlite.Sqlite3.execute(db, "DELETE FROM work_orders")
end
