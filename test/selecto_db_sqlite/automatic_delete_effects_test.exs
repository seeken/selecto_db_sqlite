defmodule SelectoDBSQLite.AutomaticDeleteEffectsTest do
  use ExUnit.Case, async: true
  alias Selecto.Write.{Batch, Command, Error, Graph}
  alias Selecto.Write.Graph.{Node, Row}
  alias SelectoDBSQLite.Adapter

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory, foreign_keys: true)
    on_exit(fn -> Adapter.disconnect(db) end)
    %{db: db}
  end

  for action <- ["CASCADE", "SET NULL", "SET DEFAULT"] do
    test "governed DELETE refuses incoming #{action} without business DML", %{db: db} do
      tables(db, unquote(action))
      before = sql(db, "SELECT total_changes()")

      assert {:error, %{details: %{code: :native_write_effects_not_evaluable}}} =
               Adapter.preview_write(db, delete(1))

      assert {:error, %{details: %{code: :native_write_effects_not_evaluable}}} =
               Adapter.execute_write_unsafe(db, delete(1))

      assert sql(db, "SELECT * FROM items") == [[1, "ab"], [2, "other"]]
      assert sql(db, "SELECT owner FROM children") == [["ab"]]
      assert sql(db, "SELECT total_changes()") == before
    end

    test "scoped incoming #{action} absence retains unrelated DELETE", %{db: db} do
      tables(db, unquote(action))
      assert {:ok, %{affected_rows: 1}} = Adapter.execute_write_unsafe(db, delete(2))
      assert sql(db, "SELECT id FROM items") == [[1]]
      assert sql(db, "SELECT owner FROM children") == [["ab"]]
    end
  end

  test "batch introduction of a currently absent child refuses before the first DML", %{db: db} do
    tables(db, "CASCADE")
    sql(db, "DELETE FROM children")

    {:ok, insert} =
      Command.new(%{
        operation: :insert,
        relation: "children",
        assignments: [%{field: :owner, value: {:literal, "ab"}}]
      })

    {:ok, batch} = Batch.new([insert, delete(1)])
    before = sql(db, "SELECT total_changes()")

    assert {:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} =
             Adapter.execute_write_unsafe(db, batch)

    assert sql(db, "SELECT id FROM items") == [[1], [2]]
    assert sql(db, "SELECT * FROM children") == []
    assert sql(db, "SELECT total_changes()") == before
  end

  test "implicit composite primary-key references use the parent comparator", %{db: db} do
    sql(
      db,
      "CREATE TABLE items(id TEXT COLLATE NOCASE,ref INTEGER,PRIMARY KEY(id,ref)) WITHOUT ROWID"
    )

    sql(
      db,
      "CREATE TABLE children(owner TEXT,ref INTEGER,FOREIGN KEY(owner,ref) REFERENCES items ON DELETE CASCADE)"
    )

    sql(db, "INSERT INTO items VALUES('A',1)")
    sql(db, "INSERT INTO children VALUES('a',1)")
    before = sql(db, "SELECT total_changes()")

    assert {:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} =
             Adapter.execute_write_unsafe(db, delete("A"))

    assert sql(db, "SELECT total_changes()") == before
  end

  test "caller transaction and nonautomatic constraints retain their authority", %{db: db} do
    tables(db, "NO ACTION")
    sql(db, "DELETE FROM children")
    sql(db, "BEGIN")
    assert {:ok, %{affected_rows: 1}} = Adapter.execute_write_unsafe(db, delete(1))
    sql(db, "ROLLBACK")
    assert sql(db, "SELECT id FROM items") == [[1], [2]]
  end

  test "prepared deletion absence uses the preparation's context", %{db: db} do
    tables(db, "CASCADE")
    command = %{delete(2) | predicate: {:eq, {:field, :id}, {:context, :selected_id}}}

    assert {:ok, %{affected_rows: 1}} =
             Adapter.execute_prepared_write_unsafe(db, fn _ ->
               {:ok, command, %{selected_id: 2}}
             end)

    assert sql(db, "SELECT id FROM items") == [[1]]
    assert sql(db, "SELECT owner FROM children") == [["ab"]]
  end

  test "TEMP target shadows cannot substitute a different incoming FK catalog", %{db: db} do
    sql(db, "CREATE TABLE items(id INTEGER PRIMARY KEY)")
    sql(db, "CREATE TEMP TABLE items(id INTEGER PRIMARY KEY)")
    sql(db, "CREATE TEMP TABLE children(owner INTEGER REFERENCES items(id) ON DELETE CASCADE)")
    sql(db, "INSERT INTO temp.items VALUES(1)")
    sql(db, "INSERT INTO temp.children VALUES(1)")
    before = sql(db, "SELECT total_changes()")

    assert {:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} =
             Adapter.execute_write_unsafe(db, delete(1))

    assert sql(db, "SELECT * FROM temp.children") == [[1]]
    assert sql(db, "SELECT total_changes()") == before
  end

  test "a sibling trigger cannot invalidate incoming-reference absence", %{db: db} do
    tables(db, "CASCADE")
    sql(db, "DELETE FROM children")
    sql(db, "CREATE TABLE audit_events(id INTEGER)")

    sql(
      db,
      "CREATE TRIGGER populate_child AFTER INSERT ON audit_events BEGIN INSERT INTO children VALUES('ab'); END"
    )

    {:ok, insert} =
      Command.new(%{
        operation: :insert,
        relation: "audit_events",
        assignments: [%{field: :id, value: {:literal, 1}}]
      })

    {:ok, batch} = Batch.new([insert, delete(1)])
    before = sql(db, "SELECT total_changes()")

    assert {:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} =
             Adapter.execute_write_unsafe(db, batch)

    assert sql(db, "SELECT total_changes()") == before
  end

  test "graph delete-missing effects refuse before a root insert", %{db: db} do
    tables(db, "CASCADE")

    {:ok, insert} =
      Command.new(%{
        operation: :insert,
        relation: "items",
        assignments: [
          %{field: :id, value: {:literal, 3}},
          %{field: :reference, value: {:literal, "new"}}
        ],
        returning: [:id]
      })

    root = %Node{
      id: "root",
      path: [],
      relation: "items",
      strategy: :ordered,
      rows: [%Row{id: "row", path: [], command: insert}]
    }

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

    assert {:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} =
             Adapter.execute_write_unsafe(db, graph)

    assert sql(db, "SELECT total_changes()") == before
  end

  defp tables(db, action) do
    sql(db, "CREATE TABLE items(id INTEGER PRIMARY KEY,reference TEXT UNIQUE)")

    sql(
      db,
      "CREATE TABLE children(owner TEXT DEFAULT NULL REFERENCES items(reference) ON DELETE #{action})"
    )

    sql(db, "INSERT INTO items VALUES(1,'ab'),(2,'other')")
    sql(db, "INSERT INTO children VALUES('ab')")
  end

  defp delete(id) do
    {:ok, command} =
      Command.new(%{
        operation: :delete,
        relation: "items",
        predicate: {:eq, {:field, :id}, {:literal, id}},
        expected_cardinality: {:exactly, 1}
      })

    command
  end

  defp sql(db, statement) do
    {:ok, result} = Adapter.execute(db, statement, [], [])
    result.rows
  end
end
