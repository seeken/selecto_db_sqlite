defmodule SelectoDBSQLite.DocumentObjectRelationTest do
  use ExUnit.Case, async: true
  alias Selecto.Document.{Fixtures, Missing, ShapeRelease}
  alias Selecto.Query.{Plan, Runtime}
  alias SelectoDBSQLite.{Adapter, DocumentQueryAdapter}

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:")
    :ok = Exqlite.Sqlite3.execute(db, "CREATE TABLE work_orders (document TEXT NOT NULL)")

    :ok =
      Exqlite.Sqlite3.execute(
        db,
        "CREATE INDEX tenant_identity ON work_orders (json_extract(document, '$.\"tenant_id\"'), json_extract(document, '$.\"_id\"'))"
      )

    on_exit(fn -> Exqlite.Sqlite3.close(db) end)
    %{db: db, release: Fixtures.object_relation_release()}
  end

  test "native predicates project published object fields with parent identity metadata", %{
    db: db,
    release: release
  } do
    insert(db, document(%{"due_at" => nil, "timezone" => "UTC"}))

    assert {:ok, result} =
             execute(db, release, %{
               "select" => ["timezone", "due_at"],
               "where" => condition("timezone", "eq", "UTC")
             })

    assert result.columns == ["timezone", "due_at"]
    assert result.rows == [["UTC", nil]]
    assert result.next_cursor == nil

    assert result.metadata["relation_identity"] == %{
             "kind" => "parent",
             "parent_relation" => "work_orders",
             "parent_identity" => "wo-1"
           }

    assert result.metadata["pushdown"] == [
             "tenant",
             "parent_identity",
             "predicate",
             "zero_or_one"
           ]

    assert {:ok, %{rows: []}} =
             execute(db, release, %{"where" => condition("timezone", "eq", "EST")})
  end

  test "absence, null, empty objects and child missing/null are distinct", %{
    db: db,
    release: release
  } do
    for {value, expected} <- [
          {%Missing{}, []},
          {nil, []},
          {%{}, [[%Missing{}, %Missing{}]]},
          {%{"due_at" => nil}, [[nil, %Missing{}]]}
        ] do
      clear(db)
      insert(db, document(value))

      assert {:ok, %{rows: ^expected}} =
               execute(db, release, %{"select" => ["due_at", "timezone"]})
    end

    for {op, expected} <- [
          {"exists", [[nil]]},
          {"missing", []},
          {"is_null", [[nil]]},
          {"is_not_null", []}
        ] do
      assert {:ok, %{rows: ^expected}} =
               execute(db, release, %{
                 "select" => ["due_at"],
                 "where" => %{"field" => "due_at", "op" => op}
               })
    end
  end

  test "false child predicates cannot conceal invalid parent or object shapes", %{
    db: db,
    release: release
  } do
    invalid = [
      document([]),
      document("wrong container"),
      document(7),
      document(false),
      document(%{"due_at" => 7}),
      document(%{"timezone" => "UTC"}) |> Map.delete("state"),
      document(%{"timezone" => "UTC"}) |> Map.put("parts", [%{}])
    ]

    for doc <- invalid do
      clear(db)
      insert(db, doc)

      assert {:error, _} =
               execute(db, release, %{"where" => condition("timezone", "eq", "never")})
    end
  end

  test "parent lookup is tenant scoped and duplicate parents fail before filtering", %{
    db: db,
    release: release
  } do
    insert(db, document(%{"timezone" => "UTC"}))
    insert(db, document(7) |> Map.put("tenant_id", "tenant-b"))
    assert {:ok, %{rows: [["UTC"]]}} = execute(db, release, %{"select" => ["timezone"]})
    assert {:ok, %{rows: []}} = execute(db, release, %{"parent_identity" => "unknown"})

    insert(db, document(%{"timezone" => "EST"}))

    assert {:error, _} =
             execute(db, release, %{"where" => condition("timezone", "eq", "never")})
  end

  test "native scalar-array membership cannot conceal invalid owned object fields", %{db: db} do
    labels = Fixtures.scalar_array_shape()["relations"]["work_order_parts"]["fields"]["labels"]

    release =
      Fixtures.object_relation_shape()
      |> put_in(["relations", "work_order_schedule", "fields", "labels"], labels)
      |> approve()

    insert(db, document(%{"timezone" => "UTC", "labels" => ["urgent", "urgent"]}))

    for {op, value, expected} <- [
          {"contains", "urgent", [["UTC"]]},
          {"contains_any", [], []},
          {"contains_all", [], [["UTC"]]},
          {"contains_all", ["urgent", "urgent"], [["UTC"]]}
        ] do
      assert {:ok, %{rows: ^expected}} =
               execute(db, release, %{
                 "select" => ["timezone"],
                 "where" => condition("labels", op, value)
               })
    end

    for labels <- [["urgent", 1], List.duplicate("urgent", 9)] do
      clear(db)
      insert(db, document(%{"labels" => labels}))

      assert {:error, _} =
               execute(db, release, %{"where" => condition("labels", "contains", "absent")})

      assert {:error, _} = root_execute(db, release, %{"select" => ["id"]})

      assert {:error, _} =
               root_execute(db, release, %{"aggregate" => [%{"op" => "count", "as" => "total"}]})
    end
  end

  test "source and predicate parameters remain bound and canonical execution rejects tampering",
       %{db: db, release: release} do
    value = "x' OR 1=1 --"
    insert(db, document(%{"timezone" => value}) |> Map.put("_id", value))

    plan =
      plan(release, %{
        "parent_identity" => value,
        "select" => ["timezone"],
        "where" => condition("timezone", "eq", value)
      })

    assert {:ok, compiled} = Runtime.compile(plan, DocumentQueryAdapter, db)
    refute compiled.artifact.sql =~ value
    assert Enum.count(compiled.artifact.params, &(&1 == value)) == 2
    assert {:ok, %{rows: [[^value]]}} = Runtime.execute(plan, DocumentQueryAdapter, db)

    assert {:ok, %{"indexed_search" => true, "unindexed_sort" => false}} =
             DocumentQueryAdapter.explain_query(db, compiled, [])

    assert {:error, _} =
             DocumentQueryAdapter.execute_query(db, put_in(compiled.artifact.sql, "SELECT 1"), [])

    :ok = Exqlite.Sqlite3.execute(db, "DROP INDEX tenant_identity")
    assert {:error, _} = Runtime.execute(plan, DocumentQueryAdapter, db)
  end

  test "parent validation evidence obeys the byte bound even when the object does not match", %{
    db: db,
    release: release
  } do
    insert(db, document(%{"timezone" => "UTC"}) |> Map.put("large", String.duplicate("x", 4096)))

    assert {:error, _} =
             execute(db, release, %{
               "where" => condition("timezone", "eq", "never"),
               "bounds" => %{"max_bytes" => 1024}
             })
  end

  test "preview omits parent, tenant and filter values while results retain their identity", %{
    db: db,
    release: release
  } do
    parent = "private-parent-preview-sentinel"
    tenant = "private-tenant-preview-sentinel"
    filter = "private-filter-preview-sentinel"

    insert(
      db,
      document(%{"timezone" => filter})
      |> Map.put("_id", parent)
      |> Map.put("tenant_id", tenant)
    )

    assert {:ok, plan} =
             Plan.new(
               release,
               "work_order_schedule",
               %{
                 "parent_identity" => parent,
                 "select" => ["timezone"],
                 "where" => condition("timezone", "eq", filter)
               },
               trusted_context: %{tenant_id: tenant}
             )

    assert {:ok, preview} = Runtime.preview(plan, DocumentQueryAdapter, db)
    encoded = Jason.encode!(preview)
    for value <- [parent, tenant, filter], do: refute(encoded =~ value)
    refute Map.has_key?(preview, "relation_identity")

    assert {:ok, result} = Runtime.execute(plan, DocumentQueryAdapter, db)
    assert result.rows == [[filter]]

    assert result.metadata["relation_identity"] == %{
             "kind" => "parent",
             "parent_relation" => "work_orders",
             "parent_identity" => parent
           }
  end

  test "the shared object corpus preserves cardinality and native predicate truth", %{
    db: db,
    release: release
  } do
    for entry <- Fixtures.object_relation_cases() do
      clear(db)
      insert(db, entry.document)

      query = %{
        "parent_identity" => entry.document["_id"],
        "select" => ["due_at", "timezone", "duration_minutes"]
      }

      if entry.valid do
        assert {:ok, result} = execute(db, release, query)
        assert result.rows == entry.rows, entry.id
      else
        assert {:error, _} = execute(db, release, query)
      end

      for {name, predicate} <- Fixtures.object_relation_predicates() do
        if entry.valid do
          assert {:ok, result} = execute(db, release, Map.put(query, "where", predicate))

          assert result.rows == if(entry.predicates[name], do: entry.rows, else: []),
                 "#{entry.id}/#{name}"
        else
          assert {:error, _} = execute(db, release, Map.put(query, "where", predicate))
        end
      end
    end
  end

  test "declared missing, null and required child policies are enforced before filtering", %{
    db: db
  } do
    for {field_path, changes, value} <- [
          {["shape", "fields", "schedule"], %{"required" => true, "missing" => "reject"},
           %Missing{}},
          {["shape", "fields", "schedule"], %{"nullable" => false}, nil},
          {["relations", "work_order_schedule", "fields", "timezone"],
           %{"required" => true, "missing" => "reject"}, %{}}
        ] do
      release =
        Fixtures.object_relation_shape()
        |> update_in(field_path, &Map.merge(&1, changes))
        |> approve()

      clear(db)
      insert(db, document(value))

      assert {:error, _} =
               execute(db, release, %{"where" => condition("timezone", "eq", "never")})
    end
  end

  test "nested object and child paths never traverse arrays or other nonobjects", %{db: db} do
    release =
      Fixtures.object_relation_shape()
      |> put_in(["shape", "fields", "schedule", "path"], ["envelope", "schedule"])
      |> put_in(["relations", "work_order_schedule", "path"], ["envelope", "schedule"])
      |> put_in(
        ["relations", "work_order_schedule", "fields", "duration_minutes", "path"],
        ["details", "minutes"]
      )
      |> approve()

    for parent <- [[%{"schedule" => %{}}], nil, 1, "scalar", true, %{}] do
      clear(db)
      insert(db, document(%Missing{}) |> Map.put("envelope", parent))
      assert {:ok, %{rows: []}} = execute(db, release, %{})
    end

    for details <- [[%{"minutes" => 3}], nil, 1, "scalar", false, %{}] do
      clear(db)

      insert(
        db,
        document(%Missing{})
        |> Map.put("envelope", %{"schedule" => %{"details" => details}})
      )

      assert {:ok, %{rows: [[%Missing{}]]}} =
               execute(db, release, %{
                 "select" => ["duration_minutes"],
                 "where" => %{"field" => "duration_minutes", "op" => "missing"}
               })

      assert {:ok, %{rows: []}} =
               execute(db, release, %{"where" => condition("duration_minutes", "gt", 0)})
    end
  end

  test "native owned-object paths support the combined 32-step boundary", %{db: db} do
    object_path = Enum.map(1..16, &"object_#{&1}")
    field_path = Enum.map(1..16, &"field_#{&1}")

    release =
      Fixtures.object_relation_shape()
      |> put_in(["shape", "fields", "schedule", "path"], object_path)
      |> put_in(["relations", "work_order_schedule", "path"], object_path)
      |> put_in(["relations", "work_order_schedule", "fields", "timezone", "path"], field_path)
      |> approve()

    nested =
      Enum.reduce(Enum.reverse(object_path ++ field_path), "UTC", fn key, value ->
        %{key => value}
      end)

    insert(db, Map.merge(document(%Missing{}), nested))

    assert {:ok, %{rows: [["UTC"]]}} =
             execute(db, release, %{
               "select" => ["timezone"],
               "where" => condition("timezone", "eq", "UTC")
             })
  end

  defp approve(shape) do
    {:ok, release} = ShapeRelease.approve(shape, approved_by: "sqlite-object-control")
    release
  end

  defp plan(release, query) do
    {:ok, plan} =
      Plan.new(
        release,
        "work_order_schedule",
        Map.put_new(query, "parent_identity", "wo-1"),
        trusted_context: %{tenant_id: "tenant-a"}
      )

    plan
  end

  defp execute(db, release, query),
    do: Runtime.execute(plan(release, query), DocumentQueryAdapter, db)

  defp root_execute(db, release, query) do
    {:ok, plan} =
      Plan.new(release, "work_orders", query, trusted_context: %{tenant_id: "tenant-a"})

    Runtime.execute(plan, DocumentQueryAdapter, db)
  end

  defp document(schedule) do
    [first | _] = Fixtures.work_orders()

    case schedule do
      %Missing{} -> Map.delete(first, "schedule")
      value -> Map.put(first, "schedule", value)
    end
  end

  defp condition(field, op, value), do: %{"field" => field, "op" => op, "value" => value}

  defp insert(db, document) do
    assert {:ok, _} =
             Adapter.execute(
               db,
               "INSERT INTO work_orders(document) VALUES (?)",
               [Jason.encode!(document)],
               []
             )
  end

  defp clear(db), do: Adapter.execute(db, "DELETE FROM work_orders", [], [])
end
