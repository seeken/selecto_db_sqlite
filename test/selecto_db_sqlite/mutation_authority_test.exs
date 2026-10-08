defmodule SelectoDBSQLite.MutationAuthorityTest do
  use ExUnit.Case, async: true

  alias Selecto.Write.{Batch, Command, Graph}
  alias Selecto.Write.Graph.{Node, Row}
  alias SelectoDBSQLite.Adapter

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory, foreign_keys: true)
    on_exit(fn -> Adapter.disconnect(db) end)
    %{db: db}
  end

  for physical <- [:main_trigger, :temp_trigger, :generated],
      operation <- [:insert, :update, :upsert, :delete] do
    test "noRules #{operation} refuses #{physical} before mutation or preview", %{db: db} do
      tables(db, unquote(physical))
      command = command(unquote(operation))
      before = snapshot(db)
      changes = sql(db, "SELECT total_changes()")
      assert refusal?(Adapter.preview_write(db, command))
      assert refusal?(Adapter.execute_write_unsafe(db, command))
      assert snapshot(db) == before
      assert sql(db, "SELECT total_changes()") == changes
    end
  end

  test "a later trigger-bearing batch target refuses before a safe earlier update", %{db: db} do
    tables(db, :main_trigger)
    sql(db, "CREATE TABLE safe_items(id INTEGER PRIMARY KEY,quantity INTEGER)")
    sql(db, "INSERT INTO safe_items VALUES(1,1)")
    safe = %{command(:update) | relation: "safe_items"}
    {:ok, batch} = Batch.new([safe, command(:update)])
    before = sql(db, "SELECT total_changes()")
    assert refusal?(Adapter.execute_write_unsafe(db, batch))
    assert sql(db, "SELECT total_changes()") == before
    assert sql(db, "SELECT quantity FROM safe_items") == [[1]]
    assert sql(db, "SELECT reference,quantity FROM items") == [["original", 1]]
  end

  test "a later graph insert target refuses before the root insert", %{db: db} do
    tables(db, :main_trigger)
    sql(db, "CREATE TABLE safe_items(id INTEGER PRIMARY KEY,quantity INTEGER)")

    safe = %{
      command(:insert)
      | relation: "safe_items",
        assignments: [%{field: :id, value: {:literal, 2}}]
    }

    root = node("root", safe)
    unsafe = node("later", command(:insert))
    {:ok, graph} = Graph.new([root, unsafe], {"root", "row"})
    before = sql(db, "SELECT total_changes()")
    assert refusal?(Adapter.preview_write(db, graph))
    assert refusal?(Adapter.execute_write_unsafe(db, graph))
    assert sql(db, "SELECT total_changes()") == before
    assert sql(db, "SELECT * FROM safe_items") == []
  end

  test "empty delete-missing generated target refuses before the root insert", %{db: db} do
    tables(db, :generated)
    sql(db, "CREATE TABLE safe_items(id INTEGER PRIMARY KEY)")

    root =
      node("root", %{
        command(:insert)
        | relation: "safe_items",
          assignments: [%{field: :id, value: {:literal, 2}}]
      })

    cleanup = %Node{
      id: "cleanup",
      path: [:cleanup],
      relation: "items",
      strategy: :sync,
      rows: [],
      identity_fields: [:id],
      sync_predicate: {:eq, {:field, :id}, {:literal, 1}},
      delete_missing?: true
    }

    {:ok, graph} = Graph.new([root, cleanup], {"root", "row"})
    before = sql(db, "SELECT total_changes()")
    assert refusal?(Adapter.execute_write_unsafe(db, graph))
    assert sql(db, "SELECT total_changes()") == before
    assert sql(db, "SELECT * FROM safe_items") == []
  end

  test "ordinary positive controls preserve the caller transaction", %{db: db} do
    tables(db, :ordinary)
    sql(db, "BEGIN")
    assert {:ok, _} = Adapter.execute_write_unsafe(db, command(:insert))
    assert {:ok, _} = Adapter.execute_write_unsafe(db, command(:update))
    assert {:ok, _} = Adapter.execute_write_unsafe(db, command(:upsert))
    assert {:ok, _} = Adapter.execute_write_unsafe(db, command(:delete))
    assert sql(db, "SELECT id FROM items") == [[2]]
    sql(db, "ROLLBACK")
    assert sql(db, "SELECT id,quantity FROM items") == [[1, 1]]
  end

  test "schema refusal leaves pending caller work and governed SELECT reads intact", %{db: db} do
    tables(db, :main_trigger)
    sql(db, "BEGIN")
    sql(db, "CREATE TABLE pending(id INTEGER)")
    sql(db, "INSERT INTO pending VALUES(9)")
    before = sql(db, "SELECT total_changes()")
    assert refusal?(Adapter.execute_write_unsafe(db, command(:update)))
    assert sql(db, "SELECT total_changes()") == before
    assert sql(db, "SELECT * FROM pending") == [[9]]
    assert {:ok, %{rows: [[1]]}} = Adapter.execute_query(db, "SELECT quantity FROM items", [], [])
    assert sql(db, "PRAGMA query_only") == [[0]]
    sql(db, "ROLLBACK")
    assert sql(db, "SELECT name FROM sqlite_master WHERE name='pending'") == []
  end

  defp tables(db, physical) do
    extra =
      if physical == :generated,
        do: ",derived TEXT GENERATED ALWAYS AS (CAST(quantity AS TEXT)) UNIQUE",
        else: ""

    sql(
      db,
      "CREATE TABLE items(id INTEGER PRIMARY KEY,reference TEXT UNIQUE,quantity INTEGER#{extra})"
    )

    sql(db, "INSERT INTO items(id,reference,quantity) VALUES(1,'original',1)")

    if physical in [:main_trigger, :temp_trigger] do
      temp = if physical == :temp_trigger, do: "TEMP ", else: ""

      sql(
        db,
        "CREATE #{temp}TRIGGER hidden_transform AFTER UPDATE OF quantity ON items BEGIN UPDATE items SET reference='changed'; END"
      )
    end

    parent = if physical == :generated, do: "derived", else: "reference"
    sql(db, "CREATE TABLE unowned(owner TEXT REFERENCES items(#{parent}) ON UPDATE CASCADE)")

    if physical != :ordinary do
      value = if physical == :generated, do: "1", else: "original"
      sql(db, "INSERT INTO unowned VALUES('#{value}')")
    end
  end

  defp command(operation) do
    assignments =
      case operation do
        :delete ->
          []

        :update ->
          [%{field: :quantity, value: {:literal, 3}}]

        _ ->
          [
            %{field: :id, value: {:literal, 2}},
            %{field: :reference, value: {:literal, "new"}},
            %{field: :quantity, value: {:literal, 3}}
          ]
      end

    metadata =
      if operation == :upsert,
        do: %{conflict_target: [:id], upsert_update_fields: [:quantity]},
        else: %{}

    {:ok, result} =
      Command.new(%{
        operation: operation,
        relation: "items",
        assignments: assignments,
        predicate: {:eq, {:field, :id}, {:literal, 1}},
        metadata: metadata
      })

    result
  end

  defp node(id, command),
    do: %Node{
      id: id,
      path: [id],
      relation: command.relation,
      strategy: :ordered,
      rows: [%Row{id: "row", path: [id], command: command}]
    }

  defp refusal?({:error, %{details: %{code: :native_write_effects_not_evaluable}}}), do: true
  defp refusal?(_), do: false
  defp snapshot(db), do: {sql(db, "SELECT * FROM items"), sql(db, "SELECT * FROM unowned")}

  defp sql(db, statement) do
    {:ok, result} = Adapter.execute(db, statement, [], [])
    result.rows
  end
end
