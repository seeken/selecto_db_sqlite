defmodule SelectoDBSQLite.InsertAdmissionTest do
  use ExUnit.Case, async: false
  alias SelectoDBSQLite.Adapter
  alias Selecto.Write.{Command, Batch, Error, Result}

  setup do
    {:ok, connection} = Adapter.connect(database: ":memory:")
    on_exit(fn -> Adapter.disconnect(connection) end)
    %{connection: connection}
  end

  test "numeric-looking text uses SQLite text comparison, not host numeric comparison", %{
    connection: connection
  } do
    execute!(connection, "CREATE TABLE items (id INTEGER PRIMARY KEY, subject TEXT)")
    guard = {:lt, {:field, "subject"}, {:literal, "10"}}

    assert {:error, %Error{type: :query_enforcement, details: %{code: :query_rule_violation}}} =
             Adapter.execute_write_unsafe(connection, command("2", :string, guard))

    assert count(connection) == 0

    assert {:ok, %Result{affected_rows: 1}} =
             Adapter.execute_write_unsafe(connection, command("1", :string, guard))

    assert {:ok, %{rows: [[1]]}} =
             Adapter.execute(
               connection,
               "SELECT count(*) FROM items WHERE subject < '10'",
               [],
               []
             )
  end

  test "collations are recovered from the column declaration and used for admission", %{
    connection: connection
  } do
    execute!(
      connection,
      "CREATE TABLE items (id INTEGER PRIMARY KEY, subject TEXT COLLATE NOCASE DEFAULT 'COLLATE RTRIM' CHECK(length(subject)>0))"
    )

    guard = {:eq, {:field, "subject"}, {:literal, "active"}}

    assert {:ok, %Result{affected_rows: 1}} =
             Adapter.execute_write_unsafe(connection, command("ACTIVE", :string, guard))

    assert {:ok, %{rows: [[1]]}} =
             Adapter.execute(
               connection,
               "SELECT count(*) FROM items WHERE subject='active'",
               [],
               []
             )
  end

  test "quoted column declarations preserve actual collation", %{connection: connection} do
    execute!(
      connection,
      "CREATE TABLE items (id INTEGER PRIMARY KEY, 'subject' TEXT COLLATE 'NOCASE')"
    )

    guard = {:eq, {:field, "subject"}, {:literal, "active"}}

    assert {:ok, %Result{affected_rows: 1}} =
             Adapter.execute_write_unsafe(connection, command("ACTIVE", :string, guard))

    assert {:ok, %{rows: [[1]]}} =
             Adapter.execute(
               connection,
               "SELECT count(*) FROM items WHERE subject='active'",
               [],
               []
             )
  end

  test "decimal storage proof rejects malformed candidates and admits actual NUMERIC affinity", %{
    connection: connection
  } do
    execute!(connection, "CREATE TABLE items (id INTEGER PRIMARY KEY, subject DECIMAL(12,2))")
    guard = {:lt, {:field, "subject"}, {:literal, 16}}

    for value <- ["0x10", "NaN", "Inf", "01", "1e9999"] do
      assert {:error, %Error{details: %{code: :query_rule_not_evaluable}}} =
               Adapter.execute_write_unsafe(connection, command(value, :decimal, guard))
    end

    assert {:ok, %Result{affected_rows: 1}} =
             Adapter.execute_write_unsafe(connection, command("10.5", :decimal, guard))

    assert {:ok, %{rows: [[1]]}} =
             Adapter.execute(connection, "SELECT count(*) FROM items WHERE subject<16", [], [])

    assert Adapter.write_capabilities(connection).typed_insert_precision == false
  end

  test "NULL only satisfies a true SQL predicate and compound guards retain binding order", %{
    connection: connection
  } do
    execute!(connection, "CREATE TABLE items (id INTEGER PRIMARY KEY, subject TEXT)")
    guard = {:or, [{:lt, {:field, "subject"}, {:literal, "10"}}, {:is_null, {:field, "subject"}}]}

    assert {:ok, %Result{affected_rows: 1}} =
             Adapter.execute_write_unsafe(connection, command(nil, :string, guard))

    execute!(connection, "DELETE FROM items")

    assert {:error, %Error{details: %{code: :query_rule_violation}}} =
             Adapter.execute_write_unsafe(
               connection,
               command(nil, :string, {:not, {:eq, {:field, "subject"}, {:literal, "active"}}})
             )
  end

  test "schema mismatches, missing guarded defaults, triggers, and temp shadows fail before DML",
       %{connection: connection} do
    execute!(connection, "CREATE TABLE items (id INTEGER PRIMARY KEY, subject INTEGER DEFAULT 1)")
    guard = {:eq, {:field, "subject"}, {:literal, "1"}}

    assert {:error, %Error{details: %{code: :query_rule_not_evaluable}}} =
             Adapter.execute_write_unsafe(connection, command("1", :string, guard))

    default = %{command(1, :integer, guard) | assignments: [%{field: "id", value: {:literal, 1}}]}

    assert {:error, %Error{details: %{code: :query_rule_not_evaluable}}} =
             Adapter.execute_write_unsafe(connection, default)

    execute!(
      connection,
      "CREATE TRIGGER transformed AFTER INSERT ON items BEGIN UPDATE items SET subject=999; END"
    )

    assert {:error, %Error{details: %{code: :query_rule_not_evaluable}}} =
             Adapter.execute_write_unsafe(connection, command(1, :integer, guard))

    execute!(connection, "DROP TRIGGER transformed")
    execute!(connection, "CREATE TEMP TABLE items (id INTEGER, subject INTEGER)")

    assert {:error, %Error{details: %{code: :query_rule_not_evaluable}}} =
             Adapter.execute_write_unsafe(connection, command(1, :integer, guard))

    assert count(connection) == 0
  end

  for {kind, ddl} <- [
        {:table, "CREATE TEMP TABLE ITEMS(id INTEGER, subject TEXT)"},
        {:view, "CREATE TEMP VIEW ITEMS AS SELECT id,subject FROM main.items"}
      ] do
    test "uppercase TEMP #{kind} shadow refuses guarded insert", %{connection: connection} do
      execute!(connection, "CREATE TABLE items(id INTEGER PRIMARY KEY,subject TEXT)")
      execute!(connection, unquote(ddl))
      guard = {:eq, {:field, "subject"}, {:literal, "active"}}

      assert {:error, %Error{details: %{code: :query_rule_not_evaluable}}} =
               Adapter.execute_write_unsafe(connection, command("active", :string, guard))

      for table <- ["main.items", "temp.ITEMS"] do
        assert {:ok, %{rows: [[0]]}} =
                 Adapter.execute(connection, "SELECT count(*) FROM " <> table, [], [])
      end
    end
  end

  test "unselected generated storage refuses guarded insert", %{connection: connection} do
    execute!(
      connection,
      "CREATE TABLE items(id INTEGER PRIMARY KEY,subject TEXT,derived TEXT GENERATED ALWAYS AS (lower(subject)))"
    )

    guard = {:eq, {:field, "subject"}, {:literal, "active"}}

    assert {:error, %Error{details: %{code: :query_rule_not_evaluable}}} =
             Adapter.execute_write_unsafe(connection, command("active", :string, guard))

    assert count(connection) == 0
  end

  test "FTS5 shadow table cannot establish ordinary insert storage", %{connection: connection} do
    execute!(connection, "CREATE VIRTUAL TABLE documents USING fts5(body)")
    guard = {:eq, {:field, "id"}, {:literal, 91}}

    candidate = %{
      command("active", :string, guard)
      | relation: "documents_data",
        assignments: [%{field: "id", value: {:literal, 91}}]
    }

    assert {:error, %Error{details: %{code: :query_rule_not_evaluable}}} =
             Adapter.execute_write_unsafe(connection, candidate)

    assert {:ok, %{rows: [[0]]}} =
             Adapter.execute(
               connection,
               "SELECT count(*) FROM documents_data WHERE id=91",
               [],
               []
             )
  end

  test "guarded NULL integer primary keys cannot hide rowid generation", %{connection: connection} do
    execute!(connection, "CREATE TABLE items (id INTEGER PRIMARY KEY, subject TEXT)")

    candidate = %{
      command("active", :string, {:is_null, {:field, "id"}})
      | assignments: [
          %{field: "id", value: {:literal, nil}},
          %{field: "subject", value: {:literal, "active"}}
        ]
    }

    assert {:error, %Error{details: %{code: :query_rule_not_evaluable}}} =
             Adapter.execute_write_unsafe(connection, candidate)

    assert count(connection) == 0
  end

  test "guard failure rolls back earlier batch commands inside caller transactions", %{
    connection: connection
  } do
    execute!(connection, "CREATE TABLE items (id INTEGER PRIMARY KEY, subject TEXT)")
    execute!(connection, "BEGIN")
    execute!(connection, "INSERT INTO items VALUES (9, 'caller')")
    guard = {:lt, {:field, "subject"}, {:literal, "10"}}
    first = command("1", :string, guard)

    second = %{
      command("2", :string, guard)
      | assignments: [
          %{field: "id", value: {:literal, 2}},
          %{field: "subject", value: {:literal, "2"}}
        ]
    }

    assert {:ok, batch} = Batch.new([first, second])

    assert {:error, %Error{details: %{code: :query_rule_violation}}} =
             Adapter.execute_write_unsafe(connection, batch)

    assert count(connection) == 1
    execute!(connection, "ROLLBACK")
    assert count(connection) == 0
  end

  defp command(value, type, guard) do
    assert {:ok, command} =
             Command.new(%{
               operation: :insert,
               relation: :items,
               assignments: [
                 %{field: "id", value: {:literal, 1}},
                 %{field: "subject", value: {:literal, value}}
               ],
               returning: :none,
               required_capabilities: [:typed_insert_admission],
               metadata: %{
                 field_types: %{id: :integer, subject: type},
                 insert_admission: %{storage_backend: :sqlite, predicate: guard}
               }
             })

    command
  end

  defp execute!(connection, sql), do: assert({:ok, _} = Adapter.execute(connection, sql, [], []))

  defp count(connection) do
    assert {:ok, %{rows: [[count]]}} =
             Adapter.execute(connection, "SELECT count(*) FROM items", [], [])

    count
  end
end
