defmodule SelectoDBSQLite.TenantForeignKeyGuardTest do
  use ExUnit.Case, async: false

  alias Selecto.Write.{Command, Error, Preview, Result}
  alias SelectoDBSQLite.Adapter

  @tenant_guard %{
    field: :project_id,
    relation: :projects,
    target_field: :id,
    tenant_field: :tenant_id,
    tenant_value: 7
  }

  setup do
    {:ok, connection} = Adapter.connect(database: ":memory:")

    execute!(
      connection,
      "CREATE TABLE projects (id INTEGER PRIMARY KEY, tenant_id BIGINT NOT NULL)"
    )

    execute!(connection, """
    CREATE TABLE tasks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      tenant_id BIGINT NOT NULL,
      project_id BIGINT NOT NULL REFERENCES projects(id),
      name VARCHAR NOT NULL
    )
    """)

    execute!(connection, "INSERT INTO projects (id, tenant_id) VALUES (70, 7), (80, 8)")

    execute!(
      connection,
      "INSERT INTO tasks (id, tenant_id, project_id, name) VALUES (1, 7, 70, 'seed')"
    )

    on_exit(fn -> Exqlite.Sqlite3.close(connection) end)
    %{connection: connection}
  end

  test "a tenant guard binds the referenced row's tenant behind an alias" do
    assert {:ok, %Preview{statements: [%{text: sql, params: [7, 80, "t", 80, 7]}]}} =
             Adapter.preview_write(:unused, insert!(80), [])

    assert sql ==
             ~s|INSERT INTO "tasks" ("tenant_id", "project_id", "name") SELECT ?, ?, ? | <>
               ~s|WHERE EXISTS (SELECT 1 FROM "projects" AS "selecto_fk_parent" | <>
               ~s|WHERE "selecto_fk_parent"."id" = ? AND "selecto_fk_parent"."tenant_id" = ?)|

    assert {:ok, %Preview{statements: [%{text: update_sql, params: [80, "t", 1, 7, 80, 7]}]}} =
             Adapter.preview_write(:unused, update!(80), [])

    assert update_sql =~
             ~s|AND EXISTS (SELECT 1 FROM "projects" AS "selecto_fk_parent" | <>
               ~s|WHERE "selecto_fk_parent"."id" = ? AND "selecto_fk_parent"."tenant_id" = ?)|
  end

  test "a guard naming a tenant field without a usable tenant value fails closed" do
    for guard <- invalid_tenant_guards() do
      command = insert!(80, [guard])

      assert {:error, %Error{type: :invalid_foreign_key_guard}} =
               Adapter.preview_write(:unused, command, [])
    end
  end

  test "a tenant-7 write cannot reference tenant 8's parent", %{connection: connection} do
    assert {:error, %Error{type: :cardinality_mismatch, details: %{actual: 0}}} =
             Adapter.execute_write(connection, insert!(80), [])

    assert {:error, %Error{type: :cardinality_mismatch, details: %{actual: 0}}} =
             Adapter.execute_write(connection, update!(80), [])

    assert rows!(connection, "SELECT id, tenant_id, project_id, name FROM tasks ORDER BY id") ==
             [[1, 7, 70, "seed"]]

    assert {:ok, %Result{affected_rows: 1}} =
             Adapter.execute_write(connection, insert!(70), [])

    assert {:ok, %Result{affected_rows: 1}} =
             Adapter.execute_write(connection, update!(70), [])

    assert rows!(connection, "SELECT tenant_id, project_id, name FROM tasks ORDER BY id") ==
             [[7, 70, "t"], [7, 70, "t"]]
  end

  defp insert!(project_id, guards \\ [@tenant_guard]) do
    command!(%{
      operation: :insert,
      relation: :tasks,
      assignments: [
        %{field: :tenant_id, value: {:literal, 7}},
        %{field: :project_id, value: {:literal, project_id}},
        %{field: :name, value: {:literal, "t"}}
      ],
      metadata: %{foreign_key_guards: guards}
    })
  end

  defp update!(project_id) do
    command!(%{
      operation: :update,
      relation: :tasks,
      assignments: [
        %{field: :project_id, value: {:literal, project_id}},
        %{field: :name, value: {:literal, "t"}}
      ],
      predicate:
        {:and, [{:eq, {:field, :id}, {:literal, 1}}, {:eq, {:field, :tenant_id}, {:literal, 7}}]},
      metadata: %{foreign_key_guards: [@tenant_guard]}
    })
  end

  defp invalid_tenant_guards do
    base = Map.drop(@tenant_guard, [:tenant_field, :tenant_value])

    [
      Map.put(base, :tenant_field, :tenant_id),
      Map.merge(base, %{tenant_field: :tenant_id, tenant_value: nil}),
      Map.merge(base, %{tenant_field: 7, tenant_value: 7}),
      Map.merge(base, %{tenant_field: nil, tenant_value: 7}),
      Map.merge(base, %{tenant_field: " ", tenant_value: 7})
    ]
  end

  defp command!(attrs) do
    {:ok, command} = Command.new(attrs)
    command
  end

  defp execute!(connection, sql), do: assert({:ok, _} = Adapter.execute(connection, sql, [], []))

  defp rows!(connection, sql) do
    assert {:ok, %{rows: rows}} = Adapter.execute(connection, sql, [], [])
    rows
  end
end
