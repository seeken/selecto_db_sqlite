defmodule SelectoDBSQLite.WriteAdapterTest do
  use ExUnit.Case, async: false

  alias Selecto.Write
  alias Selecto.Write.{AdapterConformance, Batch, Command, Error, Graph, Result}
  alias Selecto.Write.Graph.{Binding, Node, Row}
  alias SelectoDBSQLite.Adapter

  setup do
    {:ok, connection} = Adapter.connect(database: ":memory:")

    execute!(connection, """
    CREATE TABLE items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      tenant_id BIGINT NOT NULL,
      external_id VARCHAR NOT NULL,
      name VARCHAR NOT NULL,
      UNIQUE (tenant_id, external_id)
    )
    """)

    execute!(connection, """
    CREATE TABLE children (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      tenant_id BIGINT NOT NULL,
      item_id BIGINT NOT NULL REFERENCES items(id),
      name VARCHAR NOT NULL
    )
    """)

    on_exit(fn -> Exqlite.Sqlite3.close(connection) end)
    %{connection: connection, selecto: %Selecto{adapter: Adapter, connection: connection}}
  end

  test "reports versioned truthful write capabilities", %{selecto: selecto} do
    assert {:ok, capabilities} = Write.capabilities(selecto)
    assert capabilities.protocol_version == 1
    assert capabilities.write_graph
    assert capabilities.generated_keys == :returning
    refute capabilities.merge
    assert capabilities.server_version
    assert Adapter.write_capabilities(:unused).server_version == nil
  end

  test "passes portable preview conformance", %{selecto: selecto} do
    assert {:ok, report} = AdapterConformance.check(selecto)
    assert report.capabilities.dialect == :sqlite
  end

  test "executes governed flat writes and normalizes cardinality", %{selecto: selecto} do
    insert =
      command!(%{
        operation: :insert,
        relation: :items,
        assignments: [
          %{field: :tenant_id, value: {:context, :tenant_id}},
          %{field: :external_id, value: {:literal, "flat"}},
          %{field: :name, value: {:literal, "First"}}
        ],
        returning: [:id, :tenant_id, :name]
      })

    assert {:ok, %Result{affected_rows: 1, rows: [%{"id" => id, "tenant_id" => 7}]}} =
             Write.execute(selecto, insert, context: %{tenant_id: 7})

    update =
      command!(%{
        operation: :update,
        relation: :items,
        assignments: [%{field: :name, value: {:literal, "Updated"}}],
        predicate:
          {:and,
           [
             {:eq, {:field, :id}, {:literal, id}},
             {:eq, {:field, :tenant_id}, {:context, :tenant_id}}
           ]},
        returning: [:id, :name]
      })

    assert {:ok, %Result{affected_rows: 1, rows: [%{"name" => "Updated"}]}} =
             Write.execute(selecto, update, context: %{tenant_id: 7})

    upsert =
      command!(%{
        operation: :upsert,
        relation: :items,
        assignments: [
          %{field: :tenant_id, value: {:literal, 7}},
          %{field: :external_id, value: {:literal, "flat"}},
          %{field: :name, value: {:literal, "Upserted"}}
        ],
        metadata: %{conflict_target: [:tenant_id, :external_id], upsert_update_fields: [:name]},
        returning: [:id, :name]
      })

    assert {:ok, %Result{affected_rows: 1, rows: [%{"id" => ^id, "name" => "Upserted"}]}} =
             Write.execute(selecto, upsert)

    delete =
      command!(%{
        operation: :delete,
        relation: :items,
        predicate:
          {:and,
           [
             {:eq, {:field, :id}, {:literal, id}},
             {:eq, {:field, :tenant_id}, {:literal, 7}}
           ]},
        returning: [:id]
      })

    assert {:ok, %Result{affected_rows: 1, rows: [%{"id" => ^id}]}} =
             Write.execute(selecto, delete)
  end

  test "rolls back a cardinality mismatch", %{connection: connection, selecto: selecto} do
    execute!(
      connection,
      "INSERT INTO items (tenant_id, external_id, name) VALUES (7, 'a', 'A'), (7, 'b', 'B')"
    )

    command =
      command!(%{
        operation: :update,
        relation: :items,
        assignments: [%{field: :name, value: {:literal, "Changed"}}],
        predicate: {:eq, {:field, :tenant_id}, {:literal, 7}},
        expected_cardinality: {:exactly, 1},
        returning: :none
      })

    assert {:error, %Error{type: :cardinality_mismatch, details: %{actual: 2}}} =
             Write.execute(selecto, command)

    assert rows!(connection, "SELECT name FROM items ORDER BY external_id") == [["A"], ["B"]]
  end

  test "rolls back a complete batch after a later constraint failure", %{
    connection: connection,
    selecto: selecto
  } do
    first = insert_command("duplicate", "First")
    duplicate = insert_command("duplicate", "Second")
    {:ok, batch} = Batch.new([first, duplicate])

    assert {:error, %Error{type: :execution_failed}} = Write.execute(selecto, batch)
    assert rows!(connection, "SELECT COUNT(*) FROM items") == [[0]]
  end

  test "executes a generated-key graph atomically without native MERGE", %{
    connection: connection,
    selecto: selecto
  } do
    root =
      insert_command("graph", "Graph")
      |> Map.put(:returning, [:id])

    child =
      command!(%{
        operation: :insert,
        relation: :children,
        assignments: [
          %{field: :tenant_id, value: {:literal, 7}},
          %{field: :name, value: {:literal, "Child"}}
        ],
        returning: [:id, :item_id]
      })

    nodes = [
      %Node{
        id: "root",
        path: [],
        relation: :items,
        strategy: :ordered,
        rows: [%Row{id: "root", path: [], command: root}]
      },
      %Node{
        id: "children",
        path: [:children],
        relation: :children,
        strategy: :ordered,
        rows: [
          %Row{
            id: "0",
            path: [:children, 0],
            command: child,
            bindings: [
              %Binding{
                field: :item_id,
                from_node: "root",
                from_row: "root",
                from_field: :id
              }
            ]
          }
        ]
      }
    ]

    {:ok, graph} = Graph.new(nodes, {"root", "root"}, metadata: %{root_returning: [:id]})

    assert {:ok,
            %Result{
              operation: :graph,
              affected_rows: 2,
              rows: [%{"id" => parent_id}],
              metadata: %{node_strategies: %{"root" => :ordered_fallback}}
            }} = Write.execute(selecto, graph)

    assert rows!(connection, "SELECT item_id, name FROM children") == [[parent_id, "Child"]]
  end

  test "foreign-key source guards fail before inserting", %{
    connection: connection,
    selecto: selecto
  } do
    guarded =
      command!(%{
        operation: :insert,
        relation: :children,
        assignments: [
          %{field: :tenant_id, value: {:literal, 7}},
          %{field: :item_id, value: {:literal, 999}},
          %{field: :name, value: {:literal, "Orphan"}}
        ],
        metadata: %{
          field_types: %{tenant_id: :integer, item_id: :integer, name: :string},
          foreign_key_guards: [
            %{field: :item_id, relation: :items, target_field: :id}
          ]
        },
        returning: [:id]
      })

    assert {:error, %Error{type: :cardinality_mismatch, details: %{actual: 0}}} =
             Write.execute(selecto, guarded)

    assert rows!(connection, "SELECT COUNT(*) FROM children") == [[0]]
  end

  defp insert_command(external_id, name) do
    command!(%{
      operation: :insert,
      relation: :items,
      assignments: [
        %{field: :tenant_id, value: {:literal, 7}},
        %{field: :external_id, value: {:literal, external_id}},
        %{field: :name, value: {:literal, name}}
      ],
      returning: [:id]
    })
  end

  defp command!(attrs) do
    {:ok, command} = Command.new(attrs)
    command
  end

  defp execute!(connection, sql, params \\ []) do
    assert {:ok, _result} = Adapter.execute(connection, sql, params, [])
  end

  defp rows!(connection, sql, params \\ []) do
    assert {:ok, %{rows: rows}} = Adapter.execute(connection, sql, params, [])
    rows
  end
end
