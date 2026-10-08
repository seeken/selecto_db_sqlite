defmodule SelectoDBSQLite.SchemaReplaceTest do
  use ExUnit.Case, async: true

  alias Selecto.Write.{Batch, Command, Error}
  alias SelectoDBSQLite.Adapter

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory, foreign_keys: true)
    on_exit(fn -> Adapter.disconnect(db) end)
    %{db: db}
  end

  for declaration <- [
        "id INTEGER PRIMARY KEY,reference TEXT UNIQUE ON CONFLICT REPLACE,quantity INTEGER",
        "id INTEGER PRIMARY KEY,reference TEXT,quantity INTEGER,UNIQUE(reference) ON /* policy */ CONFLICT REPLACE",
        "id INTEGER PRIMARY KEY on conflict replace,reference TEXT,quantity INTEGER",
        "id INTEGER PRIMARY KEY,reference TEXT,quantity INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 7"
      ],
      operation <- [:insert, :update, :upsert, :delete] do
    test "#{operation} rejects physical replacement: #{declaration}", %{db: db} do
      setup_rows(db, unquote(declaration))
      command = command(unquote(operation))
      before = sql(db, "SELECT total_changes()")

      assert {:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} =
               Adapter.execute_prepared_write_unsafe(db, fn _ -> {:ok, command, %{}} end)

      assert {:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} =
               Adapter.preview_prepared_write(db, fn _ -> {:ok, command, %{}} end, [])

      assert sql(db, "SELECT id,reference,quantity FROM items") == [[1, "collision", 1]]
      assert sql(db, "SELECT owner FROM unrelated") == [[1]]
      assert sql(db, "SELECT total_changes()") == before
    end
  end

  test "captured NULL query cannot admit a NOT NULL replacement default", %{db: db} do
    setup_rows(
      db,
      "id INTEGER PRIMARY KEY,reference TEXT,quantity INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 7"
    )

    command = command(:insert)

    command = %{
      command
      | assignments: [
          %{field: :id, value: {:literal, 2}},
          %{field: :reference, value: {:literal, "new"}},
          %{field: :quantity, value: {:literal, nil}}
        ],
        metadata: %{
          field_types: %{id: :integer, reference: :string, quantity: :integer},
          insert_admission: %{
            storage_backend: :sqlite,
            predicate: {:is_null, {:field, :quantity}}
          }
        }
    }

    before = sql(db, "SELECT total_changes()")

    assert {:error, %Error{details: %{code: :query_rule_not_evaluable}}} =
             Adapter.execute_prepared_write_unsafe(db, fn _ -> {:ok, command, %{}} end)

    assert sql(db, "SELECT quantity FROM items") == [[1]]
    assert sql(db, "SELECT total_changes()") == before
  end

  test "physical replacement suffix refuses before the first safe batch command", %{db: db} do
    setup_rows(
      db,
      "id INTEGER PRIMARY KEY,reference TEXT UNIQUE ON CONFLICT REPLACE,quantity INTEGER"
    )

    sql(db, "CREATE TABLE prefix(id INTEGER PRIMARY KEY,reference TEXT,quantity INTEGER)")
    {:ok, batch} = Batch.new([%{command(:insert) | relation: "prefix"}, command(:insert)])
    before = sql(db, "SELECT total_changes()")

    assert {:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} =
             Adapter.execute_prepared_write_unsafe(db, fn _ -> {:ok, batch, %{}} end)

    assert sql(db, "SELECT * FROM prefix") == []
    assert sql(db, "SELECT owner FROM unrelated") == [[1]]
    assert sql(db, "SELECT total_changes()") == before
  end

  for extra <- [
        ", note TEXT DEFAULT 'ON CONFLICT REPLACE'",
        ", note TEXT DEFAULT 'escaped '' ON CONFLICT REPLACE'",
        ", \"ON CONFLICT REPLACE\" TEXT",
        ", `ON CONFLICT REPLACE` TEXT",
        ", [ON CONFLICT REPLACE] TEXT",
        ", CONSTRAINT \"ON CONFLICT REPLACE\" UNIQUE(reference)",
        " -- ON CONFLICT REPLACE\n",
        " /* ON CONFLICT REPLACE */"
      ] do
    test "quoted or commented conflict words remain valid: #{extra}", %{db: db} do
      setup_rows(db, "id INTEGER PRIMARY KEY,reference TEXT,quantity INTEGER" <> unquote(extra))
      command = command(:insert)

      command = %{
        command
        | assignments: [
            %{field: :id, value: {:literal, 2}},
            %{field: :reference, value: {:literal, "new"}},
            %{field: :quantity, value: {:literal, 2}}
          ]
      }

      assert {:ok, %{affected_rows: 1}} =
               Adapter.execute_prepared_write_unsafe(db, fn _ -> {:ok, command, %{}} end)

      assert sql(db, "SELECT id,reference,quantity FROM items ORDER BY id") ==
               [[1, "collision", 1], [2, "new", 2]]

      assert sql(db, "SELECT owner FROM unrelated") == [[1]]
    end
  end

  test "caller transaction survives the refusal", %{db: db} do
    setup_rows(
      db,
      "id INTEGER PRIMARY KEY,reference TEXT UNIQUE ON CONFLICT REPLACE,quantity INTEGER"
    )

    sql(db, "BEGIN")
    sql(db, "UPDATE items SET quantity=3")
    before = sql(db, "SELECT total_changes()")

    assert {:error, %Error{details: %{code: :native_write_effects_not_evaluable}}} =
             Adapter.execute_prepared_write_unsafe(db, fn _ -> {:ok, command(:insert), %{}} end)

    assert sql(db, "SELECT quantity FROM items") == [[3]]
    assert sql(db, "SELECT total_changes()") == before
    sql(db, "ROLLBACK")
    assert sql(db, "SELECT quantity FROM items") == [[1]]
  end

  defp setup_rows(db, declaration) do
    sql(db, "CREATE TABLE items(#{declaration})")
    sql(db, "CREATE TABLE unrelated(owner INTEGER REFERENCES items(id) ON DELETE CASCADE)")
    sql(db, "INSERT INTO items(id,reference,quantity) VALUES(1,'collision',1)")
    sql(db, "INSERT INTO unrelated VALUES(1)")
  end

  defp command(operation) do
    attrs = %{
      operation: operation,
      relation: "items",
      assignments:
        if(operation == :delete,
          do: [],
          else: [
            %{field: :id, value: {:literal, 2}},
            %{field: :reference, value: {:literal, "collision"}},
            %{field: :quantity, value: {:literal, 2}}
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
        do:
          Map.put(attrs, :metadata, %{conflict_target: [:id], upsert_update_fields: [:reference]}),
        else: attrs

    {:ok, command} = Command.new(attrs)
    command
  end

  defp sql(db, statement) do
    {:ok, result} = Adapter.execute(db, statement, [], [])
    result.rows
  end
end
