defmodule SelectoDBSQLite.SchemaRollbackTest do
  use ExUnit.Case, async: true

  alias Selecto.Write.{Batch, Command, Error, Graph}
  alias Selecto.Write.Graph.{Node, Row}
  alias SelectoDBSQLite.Adapter

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(db) end)
    %{db: db}
  end

  for constraint <- [:unique, :not_null], operation <- [:insert, :upsert] do
    test "#{operation} #{constraint} ABORT keeps its native failure and caller work", %{db: db} do
      setup_rows(db, unquote(constraint), "ABORT")
      begin_caller(db)
      before = snapshot(db)
      changes = sql(db, "SELECT total_changes()")
      id = if unquote(constraint) == :unique or unquote(operation) == :insert, do: 3, else: 1
      name = if unquote(constraint) == :unique, do: "taken", else: nil

      command = %{
        command(unquote(operation))
        | assignments: [
            %{field: :id, value: {:literal, id}},
            %{field: :name, value: {:literal, name}}
          ]
      }

      assert {:ok, _} = Adapter.preview_write(db, command)

      assert {:error, %Error{type: :native_constraint_violation}} =
               Adapter.execute_write_unsafe(db, command)

      assert_preserved(db, before, changes)
    end
  end

  for operation <- [:insert, :update, :upsert],
      declaration <- [
        "id INTEGER PRIMARY KEY,name TEXT UNIQUE ON CONFLICT ROLLBACK,secret TEXT",
        "id INTEGER PRIMARY KEY,name TEXT,secret TEXT,UNIQUE(name) ON /* policy */ CONFLICT rollback",
        "id INTEGER PRIMARY KEY ON CONFLICT ROLLBACK,name TEXT,secret TEXT",
        "id INTEGER PRIMARY KEY,name TEXT NOT NULL ON CONFLICT ROLLBACK,secret TEXT"
      ] do
    test "#{operation} guards every real ROLLBACK spelling: #{declaration}", %{db: db} do
      setup_declaration(db, unquote(declaration))
      begin_caller(db)
      before = snapshot(db)
      changes = sql(db, "SELECT total_changes()")
      command = command(unquote(operation))

      assert_refused(Adapter.preview_write(db, command))
      assert_refused(Adapter.preview_prepared_write(db, fn _ -> {:ok, command, %{}} end, []))
      assert_refused(Adapter.execute_write_unsafe(db, command))
      assert_refused(Adapter.execute_prepared_write_unsafe(db, fn _ -> {:ok, command, %{}} end))
      assert_preserved(db, before, changes)
    end
  end

  for extra <- [
        ", note TEXT DEFAULT 'ON CONFLICT ROLLBACK'",
        ", note TEXT DEFAULT 'escaped '' ON CONFLICT ROLLBACK'",
        ", \"ON CONFLICT ROLLBACK\" TEXT",
        ", `ON CONFLICT ROLLBACK` TEXT",
        ", [ON CONFLICT ROLLBACK] TEXT",
        ", CONSTRAINT \"ON CONFLICT ROLLBACK\" UNIQUE(name)",
        " -- ON CONFLICT ROLLBACK\n",
        " /* ON CONFLICT ROLLBACK */"
      ] do
    test "quoted/commented ROLLBACK words still allow real success: #{extra}", %{db: db} do
      setup_declaration(db, "id INTEGER PRIMARY KEY,name TEXT,secret TEXT" <> unquote(extra))
      begin_caller(db)
      assert {:ok, %{affected_rows: 1}} = Adapter.execute_write_unsafe(db, command(:insert))

      assert sql(db, "SELECT id,name,secret FROM items ORDER BY id") ==
               [[1, "before", "private"], [2, "taken", "sentinel"], [3, "safe", "new"]]

      assert sql(db, "SELECT * FROM caller_work ORDER BY id") ==
               [[10, "committed"], [11, "outer sentinel"]]

      assert {:ok, :transaction} = Exqlite.Sqlite3.transaction_status(db)
      sql(db, "ROLLBACK TO SAVEPOINT caller_proof")
      sql(db, "RELEASE SAVEPOINT caller_proof")
      sql(db, "ROLLBACK")
      assert sql(db, "SELECT id FROM items ORDER BY id") == [[1], [2]]
      memory(db)
    end
  end

  test "DELETE remains supported on a ROLLBACK table", %{db: db} do
    setup_rows(db, :unique, "ROLLBACK")
    begin_caller(db)
    assert {:ok, _} = Adapter.preview_write(db, command(:delete))
    assert {:ok, %{affected_rows: 1}} = Adapter.execute_write_unsafe(db, command(:delete))
    assert sql(db, "SELECT id,name,secret FROM items") == [[2, "taken", "sentinel"]]
    assert {:ok, :transaction} = Exqlite.Sqlite3.transaction_status(db)
    sql(db, "ROLLBACK TO SAVEPOINT caller_proof")
    sql(db, "RELEASE SAVEPOINT caller_proof")
    assert sql(db, "SELECT id FROM items ORDER BY id") == [[1], [2]]
    sql(db, "ROLLBACK")
    memory(db)
  end

  for kind <- [:batch, :graph, :same_table_delete_prefix] do
    test "whole #{kind} guards a late ROLLBACK mutation before the prefix", %{db: db} do
      setup_rows(db, :unique, "ROLLBACK")
      sql(db, "CREATE TABLE prefix(id INTEGER PRIMARY KEY,name TEXT,secret TEXT)")
      begin_caller(db)
      before = snapshot(db)
      changes = sql(db, "SELECT total_changes()")
      first = %{command(:insert) | relation: "prefix"}
      last = command(:insert)

      write =
        case unquote(kind) do
          :batch ->
            {:ok, batch} = Batch.new([first, last])
            batch

          :same_table_delete_prefix ->
            {:ok, batch} = Batch.new([command(:delete), last])
            batch

          :graph ->
            {:ok, graph} =
              Graph.new([node("prefix", first), node("last", last)], {"prefix", "row"})

            graph
        end

      assert_refused(Adapter.preview_write(db, write))
      assert_refused(Adapter.preview_prepared_write(db, fn _ -> {:ok, write, %{}} end, []))
      assert_refused(Adapter.execute_write_unsafe(db, write))
      assert_refused(Adapter.execute_prepared_write_unsafe(db, fn _ -> {:ok, write, %{}} end))
      assert sql(db, "SELECT * FROM prefix") == []
      assert_preserved(db, before, changes)
    end
  end

  test "read-only referenced tables retain their ROLLBACK schema without blocking safe writes", %{
    db: db
  } do
    setup_rows(db, :unique, "ROLLBACK")
    sql(db, "CREATE TABLE child(id INTEGER PRIMARY KEY,parent_id INTEGER REFERENCES items(id))")
    begin_caller(db)
    before = snapshot(db)
    assert {:ok, _schema} = SelectoDBSQLite.InsertAdmission.storage_schema(db, "items", [])

    assert {:ok, _schema} =
             SelectoDBSQLite.InsertAdmission.storage_schema(db, "items", [], :delete)

    assert {:ok, %{rows: [[1, "before", "private"]]}} =
             Adapter.execute_query(
               db,
               "SELECT id,name,secret FROM main.items WHERE id=?",
               [1],
               []
             )

    {:ok, child} =
      Command.new(%{
        operation: :insert,
        relation: "child",
        assignments: [
          %{field: :id, value: {:literal, 9}},
          %{field: :parent_id, value: {:literal, 1}}
        ]
      })

    assert {:ok, _} = Adapter.preview_write(db, child)
    assert {:ok, %{affected_rows: 1}} = Adapter.execute_write_unsafe(db, child)
    assert snapshot(db) == before
    assert sql(db, "SELECT * FROM child") == [[9, 1]]
    assert {:ok, :transaction} = Exqlite.Sqlite3.transaction_status(db)
    sql(db, "ROLLBACK TO SAVEPOINT caller_proof")
    sql(db, "RELEASE SAVEPOINT caller_proof")
    assert sql(db, "SELECT * FROM child") == []
    sql(db, "ROLLBACK")
    memory(db)
  end

  test "owned and nested adapter transactions refuse without committing caller state", %{db: db} do
    setup_rows(db, :unique, "ROLLBACK")
    before = snapshot(db)
    assert_refused(Adapter.execute_write_unsafe(db, command(:insert)))
    assert {:ok, :idle} = Exqlite.Sqlite3.transaction_status(db)
    assert snapshot(db) == before

    assert {:ok, :checked} =
             Adapter.transaction(db, fn tx ->
               sql(tx, "INSERT INTO caller_work VALUES(11,'outer sentinel')")
               sql(tx, "SAVEPOINT caller_proof")
               before = snapshot(tx)
               changes = sql(tx, "SELECT total_changes()")
               assert_refused(Adapter.execute_write_unsafe(tx, command(:insert)))
               assert_preserved(tx, before, changes, false)
               {:ok, :checked}
             end)

    assert sql(db, "SELECT * FROM caller_work ORDER BY id") ==
             [[10, "committed"], [11, "outer sentinel"]]

    assert {:ok, :idle} = Exqlite.Sqlite3.transaction_status(db)
    memory(db)
  end

  defp setup_rows(db, constraint, policy) do
    declaration =
      if constraint == :unique,
        do:
          "id INTEGER PRIMARY KEY,name TEXT NOT NULL,secret TEXT NOT NULL DEFAULT 'generated',UNIQUE(name) ON CONFLICT #{policy}",
        else:
          "id INTEGER PRIMARY KEY,name TEXT NOT NULL ON CONFLICT #{policy},secret TEXT NOT NULL DEFAULT 'generated'"

    setup_declaration(db, declaration)
  end

  defp setup_declaration(db, declaration) do
    sql(db, "CREATE TABLE items(#{declaration})")
    sql(db, "CREATE TABLE caller_work(id INTEGER PRIMARY KEY,value TEXT)")

    sql(
      db,
      "INSERT INTO items(id,name,secret) VALUES(1,'before','private'),(2,'taken','sentinel')"
    )

    sql(db, "INSERT INTO caller_work VALUES(10,'committed')")
    memory(db)
  end

  defp begin_caller(db) do
    sql(db, "BEGIN")
    sql(db, "INSERT INTO caller_work VALUES(11,'outer sentinel')")
    sql(db, "SAVEPOINT caller_proof")
  end

  defp assert_preserved(db, before, changes, rollback? \\ true) do
    assert snapshot(db) == before
    assert sql(db, "SELECT total_changes()") == changes
    assert {:ok, :transaction} = Exqlite.Sqlite3.transaction_status(db)
    sql(db, "ROLLBACK TO SAVEPOINT caller_proof")
    sql(db, "RELEASE SAVEPOINT caller_proof")
    assert snapshot(db) == before
    memory(db)

    if rollback? do
      sql(db, "ROLLBACK")
      assert sql(db, "SELECT * FROM caller_work ORDER BY id") == [[10, "committed"]]
      assert {:ok, :idle} = Exqlite.Sqlite3.transaction_status(db)
    end
  end

  defp assert_refused(result),
    do: assert({:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} = result)

  defp snapshot(db),
    do: %{
      items: sql(db, "SELECT id,name,secret FROM items ORDER BY id"),
      caller_work: sql(db, "SELECT * FROM caller_work ORDER BY id")
    }

  defp memory(db) do
    assert Enum.all?(sql(db, "PRAGMA database_list"), fn [_, _, filename] -> filename == "" end)
    assert sql(db, "PRAGMA temp_store") == [[2]]
  end

  defp command(operation) do
    attrs = %{
      operation: operation,
      relation: "items",
      assignments:
        if(operation == :delete,
          do: [],
          else: [
            %{field: :id, value: {:literal, 3}},
            %{field: :name, value: {:literal, "safe"}},
            %{field: :secret, value: {:literal, "new"}}
          ]
        ),
      expected_cardinality: {:exactly, 1}
    }

    attrs =
      if operation in [:update, :delete],
        do: Map.put(attrs, :predicate, {:eq, {:field, :id}, {:literal, 1}}),
        else: attrs

    attrs =
      if operation == :upsert,
        do: Map.put(attrs, :metadata, %{conflict_target: [:id], upsert_update_fields: [:name]}),
        else: attrs

    {:ok, command} = Command.new(attrs)
    command
  end

  defp node(id, command),
    do: %Node{
      id: id,
      path: [],
      relation: command.relation,
      strategy: :ordered,
      rows: [%Row{id: "row", path: [], command: command}]
    }

  defp sql(db, statement) do
    {:ok, result} = Adapter.execute(db, statement, [], [])
    result.rows
  end
end
