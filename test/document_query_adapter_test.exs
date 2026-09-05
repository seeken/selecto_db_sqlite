defmodule SelectoDBSQLite.DocumentQueryAdapterTest do
  use ExUnit.Case, async: true
  alias Selecto.Document.{Fixtures, Missing}
  alias Selecto.Query.{Plan, Runtime}
  alias SelectoDBSQLite.{Adapter, DocumentQueryAdapter}
  @secret String.duplicate("s", 32)

  setup do
    {:ok, connection} = Adapter.connect(database: ":memory:")
    :ok = Exqlite.Sqlite3.execute(connection, "CREATE TABLE work_orders (document TEXT NOT NULL)")

    :ok =
      Exqlite.Sqlite3.execute(
        connection,
        "CREATE UNIQUE INDEX tenant_identity ON work_orders (json_extract(document, '$.\"tenant_id\"'), json_extract(document, '$.\"_id\"'))"
      )

    for doc <- Fixtures.work_orders() do
      {:ok, _} =
        Adapter.execute(
          connection,
          "INSERT INTO work_orders(document) VALUES (?)",
          [Jason.encode!(doc)],
          []
        )
    end

    on_exit(fn -> Exqlite.Sqlite3.close(connection) end)
    %{connection: connection}
  end

  test "the portable plan executes parameterized SQL and preserves missing/null", %{
    connection: connection
  } do
    plan = plan(%{"select" => ["id", "due_at", "priority"]})
    assert {:ok, result} = Runtime.execute(plan, DocumentQueryAdapter, connection)
    assert result.rows == [["wo-1", nil, 2], ["wo-2", %Missing{}, %Missing{}]]

    for {op, expected} <- [
          {"exists", ["wo-1"]},
          {"missing", ["wo-2"]},
          {"is_null", ["wo-1"]},
          {"is_not_null", []}
        ] do
      query = plan(%{"select" => ["id"], "where" => %{"field" => "due_at", "op" => op}})
      assert {:ok, result} = Runtime.execute(query, DocumentQueryAdapter, connection)
      assert List.flatten(result.rows) == expected
    end
  end

  test "bound cursor continues exact identity ordering and tenant remains mandatory", %{
    connection: connection
  } do
    assert {:ok, result} =
             Runtime.execute(
               plan(%{"select" => ["id"], "limit" => 1}),
               DocumentQueryAdapter,
               connection,
               cursor_secret: @secret
             )

    assert result.rows == [["wo-1"]]
    next = plan(%{"select" => ["id"], "limit" => 1, "cursor" => result.next_cursor})

    assert {:ok, result} =
             Runtime.execute(next, DocumentQueryAdapter, connection, cursor_secret: @secret)

    assert result.rows == [["wo-2"]]
    assert result.next_cursor == nil
  end

  test "values are bound and unsupported child relations fail preflight", %{
    connection: connection
  } do
    value = "open' OR 1=1 --"

    query =
      plan(%{
        "select" => ["id"],
        "where" => %{"field" => "state", "op" => "eq", "value" => value}
      })

    assert {:ok, compiled} = Runtime.compile(query, DocumentQueryAdapter, connection)
    refute compiled.artifact.sql =~ value
    assert value in compiled.artifact.params
    assert {:ok, %{rows: []}} = Runtime.execute(query, DocumentQueryAdapter, connection)

    {:ok, child} =
      Plan.new(Fixtures.release(), "work_order_parts", %{"parent_identity" => "wo-1"},
        trusted_context: %{tenant_id: "tenant-a"}
      )

    assert {:error, _} = Runtime.execute(child, DocumentQueryAdapter, connection)
  end

  test "ordering without a covering declared index is rejected", %{connection: connection} do
    query =
      plan(%{"select" => ["id"], "order_by" => [%{"field" => "title", "direction" => "asc"}]})

    assert {:error, _} = Runtime.execute(query, DocumentQueryAdapter, connection)
  end

  defp plan(query) do
    {:ok, plan} =
      Plan.new(Fixtures.release(), "work_orders", query,
        trusted_context: %{tenant_id: "tenant-a"},
        cursor_secret: @secret
      )

    plan
  end
end
