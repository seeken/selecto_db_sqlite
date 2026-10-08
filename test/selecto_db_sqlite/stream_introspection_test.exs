defmodule SelectoDBSQLite.StreamIntrospectionTest do
  use ExUnit.Case, async: false

  alias SelectoDBSQLite.Adapter

  setup do
    {:ok, connection} = Adapter.connect(database: ":memory:")
    on_exit(fn -> Adapter.disconnect(connection) end)
    %{connection: connection}
  end

  test "streams rows lazily, permits early halt, and preserves typed bindings", %{
    connection: connection
  } do
    sql =
      "WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < ?) SELECT n FROM numbers"

    assert {:ok, stream, ["n"]} = Adapter.stream(connection, sql, [1_000_000], [])
    assert Enum.take(stream, 3) == [[1], [2], [3]]
    assert Enum.take(stream, 2) == [[1], [2]]
    assert {:ok, %{rows: [[42]]}} = Adapter.execute(connection, "SELECT ?", [42], [])

    assert {:ok, booleans, ["flag"]} =
             Adapter.stream(connection, "SELECT $1 AS flag WHERE $1 = 1", [true], [])

    assert Enum.to_list(booleans) == [[1]]
    assert {:error, _} = Adapter.stream(connection, "SELECT * FROM nonexistent", [], [])
  end

  test "stream interrupts a long step at its deadline and leaves connection usable", %{
    connection: connection
  } do
    sql =
      "WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 100000000) SELECT sum(n) FROM numbers"

    assert {:ok, stream, _columns} = Adapter.stream(connection, sql, [], timeout: 10)
    assert_raise RuntimeError, ~r/SQLite stream timed out/, fn -> Enum.to_list(stream) end
    assert {:ok, %{rows: [[1]]}} = Adapter.execute(connection, "SELECT 1", [], [])
  end

  test "ordinary execution interrupts timed out SQLite work", %{connection: connection} do
    sql =
      "WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 100000000) SELECT sum(n) FROM numbers"

    assert {:error, :timeout} = Adapter.execute(connection, sql, [], timeout: 10)
    assert {:ok, %{rows: [[1]]}} = Adapter.execute(connection, "SELECT 1", [], [])
  end

  test "introspects columns, generated fields, composite keys, foreign keys, indexes and views",
       %{connection: connection} do
    execute!(
      connection,
      "CREATE TABLE parents (tenant INTEGER, id INTEGER, PRIMARY KEY (tenant, id))"
    )

    execute!(
      connection,
      "CREATE TABLE children (tenant INTEGER NOT NULL, id INTEGER NOT NULL, parent_id INTEGER, amount DECIMAL(12,2) DEFAULT 0, name VARCHAR(30), doubled REAL GENERATED ALWAYS AS (amount * 2) VIRTUAL, PRIMARY KEY (tenant, id), FOREIGN KEY (tenant, parent_id) REFERENCES parents(tenant, id))"
    )

    execute!(
      connection,
      "CREATE INDEX children_names ON children(name DESC) WHERE name IS NOT NULL"
    )

    execute!(connection, "CREATE VIEW named_children AS SELECT id, name FROM children")
    assert {:ok, ["children", "parents"]} = Adapter.list_tables(connection)
    assert {:ok, relations} = Adapter.list_relations(connection)
    assert Enum.find(relations, &(&1.name == "named_children")).kind == :view
    assert {:ok, metadata} = Adapter.introspect_table(connection, "children")
    assert metadata.primary_key == [:tenant, :id]
    assert metadata.field_types["amount"] == :decimal
    assert metadata.field_types["name"] == :string
    assert metadata.columns["doubled"].generated
    refute metadata.columns["tenant"].nullable
    assert length(metadata.foreign_keys) == 2

    assert Enum.find(metadata.indexes, &(&1.name == "children_names")) == %{
             name: "children_names",
             origin: "c",
             unique: false,
             partial: true,
             columns: [
               %{
                 position: 0,
                 column: "name",
                 expression: false,
                 descending: true,
                 collation: "BINARY"
               }
             ]
           }

    assert {:error, {:sqlite_relation_not_found, "nonexistent"}} =
             Adapter.introspect_table(connection, "nonexistent")

    assert :ok = Adapter.validate_connection(connection)
    assert %{adapter: :sqlite, server_version: version} = Adapter.connection_info(connection)
    assert is_binary(version)
  end

  test "quotes schema and relation names during introspection", %{connection: connection} do
    execute!(connection, ~s|CREATE TABLE "quoted'table" (id INTEGER PRIMARY KEY)|)
    assert {:ok, %{primary_key: :id}} = Adapter.introspect_table(connection, "quoted'table")
    assert {:ok, ["quoted'table"]} = Adapter.list_tables(connection)
    execute!(connection, "ATTACH DATABASE ':memory:' AS extra")
    execute!(connection, "CREATE TABLE extra.sqlitex_user_table (id INTEGER PRIMARY KEY)")
    assert {:ok, ["sqlitex_user_table"]} = Adapter.list_tables(connection, schema: "extra")

    assert {:ok, %{primary_key: :id}} =
             Adapter.introspect_table(connection, "sqlitex_user_table", schema: "extra")
  end

  test "public query streaming and query-plan callback preserve bound predicates", %{
    connection: connection
  } do
    execute!(connection, "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
    execute!(connection, "INSERT INTO items VALUES (1, 'first'), (2, 'second')")

    query =
      Selecto.configure(
        %{
          name: "items",
          source: %{
            source_table: "items",
            primary_key: :id,
            fields: [:id, :name],
            columns: %{id: %{type: :integer}, name: %{type: :string}},
            associations: %{}
          },
          schemas: %{},
          joins: %{}
        },
        connection,
        adapter: Adapter
      )
      |> Selecto.select(["name"])
      |> Selecto.filter({"id", 2})

    assert {:ok, stream} = Selecto.execute_stream(query)
    assert [{["second"], ["name"], _aliases}] = Enum.to_list(stream)
    assert {:ok, report} = Selecto.Performance.QueryAnalyzer.get_query_plan(query)
    assert report.explain_sql =~ "EXPLAIN QUERY PLAN"
    assert report.params == [2]
    assert Enum.any?(report.plan_lines, &String.contains?(&1, "INTEGER PRIMARY KEY"))

    assert {:error, %Selecto.Error{details: %{unsupported_feature: :explain_analyze}}} =
             Adapter.analyze_query(query, analyze: true)
  end

  defp execute!(connection, sql), do: assert({:ok, _} = Adapter.execute(connection, sql, [], []))
end
