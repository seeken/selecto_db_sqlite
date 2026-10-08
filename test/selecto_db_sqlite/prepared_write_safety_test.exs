defmodule SelectoDBSQLite.PreparedWriteSafetyTest do
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
    test "final prepared assignments refuse incoming #{action} before DML", %{db: db} do
      setup_tables(db, unquote(action))
      command = update(:reference, "AB")
      before = sql(db, "SELECT total_changes()")

      assert {:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} =
               execute(db, command)

      assert sql(db, "SELECT reference,quantity FROM items") == [["ab", 1]]
      assert sql(db, "SELECT owner FROM unrelated") == [["ab"]]
      assert sql(db, "SELECT total_changes()") == before

      assert {:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} =
               Adapter.preview_prepared_write(db, fn _ -> {:ok, command, %{}} end, [])

      assert sql(db, "SELECT total_changes()") == before
    end

    test "unassigned incoming #{action} key retains prepared quantity update", %{db: db} do
      setup_tables(db, unquote(action))
      assert {:ok, %{affected_rows: 1}} = execute(db, update(:quantity, 3))
      assert sql(db, "SELECT reference,quantity FROM items") == [["ab", 3]]
      assert sql(db, "SELECT owner FROM unrelated") == [["ab"]]
    end
  end

  for action <- ["NO ACTION", "RESTRICT"] do
    test "nonautomatic #{action} FK retains normal prepared writes", %{db: db} do
      setup_tables(db, unquote(action))
      sql(db, "DELETE FROM unrelated")
      assert {:ok, %{affected_rows: 1}} = execute(db, update(:reference, "AB"))
      assert sql(db, "SELECT reference FROM items") == [["AB"]]
    end
  end

  test "implicit physical primary-key target refuses inside the caller transaction", %{db: db} do
    sql(db, "CREATE TABLE items(id TEXT PRIMARY KEY,quantity INTEGER)")
    sql(db, "CREATE TABLE unrelated(owner TEXT REFERENCES items ON UPDATE CASCADE)")
    sql(db, "INSERT INTO items VALUES('ab',1)")
    sql(db, "INSERT INTO unrelated VALUES('ab')")
    sql(db, "BEGIN")
    sql(db, "UPDATE items SET quantity=2")
    command = update(:id, "AB", :id, "ab")
    before = sql(db, "SELECT total_changes()")

    assert {:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} =
             execute(db, command)

    assert sql(db, "SELECT * FROM items") == [["ab", 2]]
    assert sql(db, "SELECT owner FROM unrelated") == [["ab"]]
    assert sql(db, "SELECT total_changes()") == before
    sql(db, "ROLLBACK")
    assert sql(db, "SELECT * FROM items") == [["ab", 1]]
  end

  test "all final batch commands are checked before the first business mutation", %{db: db} do
    setup_tables(db, "CASCADE")
    {:ok, batch} = Batch.new([update(:quantity, 3), update(:reference, "AB")])
    before = sql(db, "SELECT total_changes()")

    assert {:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} =
             execute(db, batch)

    assert sql(db, "SELECT reference,quantity FROM items") == [["ab", 1]]
    assert sql(db, "SELECT total_changes()") == before
  end

  test "final prepared graph root refuses incoming automatic mutations", %{db: db} do
    setup_tables(db, "CASCADE")

    node = %Node{
      id: "root",
      path: [],
      relation: "main.items",
      strategy: :ordered,
      rows: [%Row{id: "row", path: [], command: update(:reference, "AB")}]
    }

    {:ok, graph} = Graph.new([node], {"root", "row"})
    before = sql(db, "SELECT total_changes()")

    assert {:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} =
             execute(db, graph)

    assert sql(db, "SELECT reference,quantity FROM items") == [["ab", 1]]
    assert sql(db, "SELECT total_changes()") == before
  end

  test "incoming identifiers use SQLite ASCII folding without merging Unicode columns", %{db: db} do
    sql(db, "CREATE TABLE items(id INTEGER PRIMARY KEY,ref_Ä TEXT UNIQUE,ref_ä TEXT)")
    sql(db, "CREATE TABLE unrelated(owner TEXT REFERENCES ITEMS(REF_Ä) ON UPDATE CASCADE)")
    sql(db, "INSERT INTO items VALUES(1,'ab','safe')")
    sql(db, "INSERT INTO unrelated VALUES('ab')")
    assert {:ok, %{affected_rows: 1}} = execute(db, update(:ref_ä, "changed"))
    assert sql(db, "SELECT ref_Ä,ref_ä FROM items") == [["ab", "changed"]]
    assert sql(db, "SELECT owner FROM unrelated") == [["ab"]]
    before = sql(db, "SELECT total_changes()")

    assert {:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} =
             execute(db, update(:REF_Ä, "AB"))

    assert sql(db, "SELECT total_changes()") == before
  end

  test "upsert checks only its governed conflict-update assignments", %{db: db} do
    setup_tables(db, "CASCADE")

    {:ok, command} =
      Command.new(%{
        operation: :upsert,
        relation: "items",
        assignments: [
          %{field: :id, value: {:literal, 1}},
          %{field: :reference, value: {:literal, "ab"}},
          %{field: :quantity, value: {:literal, 3}}
        ],
        metadata: %{conflict_target: [:id], upsert_update_fields: [:quantity]},
        expected_cardinality: {:exactly, 1}
      })

    assert {:ok, %{affected_rows: 1}} = execute(db, command)
    assert sql(db, "SELECT reference,quantity FROM items") == [["ab", 3]]
    assert sql(db, "SELECT owner FROM unrelated") == [["ab"]]
    unsafe = %{command | metadata: %{command.metadata | upsert_update_fields: [:reference]}}
    before = sql(db, "SELECT total_changes()")

    assert {:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} =
             execute(db, unsafe)

    assert sql(db, "SELECT total_changes()") == before
  end

  defp setup_tables(db, action) do
    sql(db, "CREATE TABLE items(id INTEGER PRIMARY KEY,reference TEXT UNIQUE,quantity INTEGER)")

    sql(
      db,
      "CREATE TABLE unrelated(owner TEXT DEFAULT NULL REFERENCES ITEMS(REFERENCE) ON UPDATE #{action})"
    )

    sql(db, "INSERT INTO items VALUES(1,'ab',1)")
    sql(db, "INSERT INTO unrelated VALUES('ab')")
  end

  defp update(field, value, key \\ :id, id \\ 1) do
    {:ok, command} =
      Command.new(%{
        operation: :update,
        relation: "main.items",
        assignments: [%{field: field, value: {:literal, value}}],
        predicate: {:eq, {:field, key}, {:literal, id}},
        expected_cardinality: {:exactly, 1}
      })

    command
  end

  defp execute(db, write),
    do: Adapter.execute_prepared_write_unsafe(db, fn _ -> {:ok, write, %{}} end)

  defp sql(db, statement) do
    {:ok, result} = Adapter.execute(db, statement, [], [])
    result.rows
  end
end
