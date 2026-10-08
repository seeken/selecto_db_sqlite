# Public Updato proof; load the selected core, Updato and adapter before execution.
ExUnit.start()
{:ok, _} = Application.ensure_all_started(:selecto_updato)
{:ok, _} = Application.ensure_all_started(:selecto_db_sqlite)

defmodule SelectoDBSQLite.NativeSchemaReplaceTest do
  use ExUnit.Case, async: true
  alias SelectoDBSQLite.Adapter

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory, foreign_keys: true)
    on_exit(fn -> Adapter.disconnect(db) end)
    %{db: db}
  end

  for declaration <- [
        "id INTEGER PRIMARY KEY,reference TEXT UNIQUE ON CONFLICT REPLACE,quantity INTEGER",
        "id INTEGER PRIMARY KEY,reference TEXT,quantity INTEGER,UNIQUE(reference) ON /* actual policy */ CONFLICT REPLACE",
        "id INTEGER PRIMARY KEY ON CONFLICT REPLACE,reference TEXT,quantity INTEGER"
      ],
      action <- ["CASCADE", "SET NULL", "SET DEFAULT"] do
    test "public write and connected preview refuse #{action}: #{declaration}", %{db: db} do
      tables(db, unquote(declaration), unquote(action))
      target = %Selecto{adapter: Adapter, connection: db}
      operation = operation(%{id: 1, reference: "collision", quantity: 2})
      before = sql(db, "SELECT total_changes()")

      assert {:error, %{details: %{code: :native_write_effects_not_evaluable}}} =
               SelectoUpdato.execute(operation, target)

      assert {:error, %{details: %{code: :native_write_effects_not_evaluable}}} =
               SelectoUpdato.preview(operation, target)

      assert sql(db, "SELECT id,reference,quantity FROM items") == [[1, "collision", 1]]
      assert sql(db, "SELECT owner FROM unrelated") == [[1]]
      assert sql(db, "SELECT total_changes()") == before
    end
  end

  test "public captured NULL predicate cannot admit a substituted NOT NULL default", %{db: db} do
    tables(
      db,
      "id INTEGER PRIMARY KEY,reference TEXT,quantity INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 7",
      "CASCADE"
    )

    target = %Selecto{adapter: Adapter, connection: db}

    query =
      domain("items")
      |> Selecto.configure(db, adapter: Adapter)
      |> Selecto.filter([{:quantity, nil}])

    operation =
      operation(%{id: 2, reference: "new", quantity: nil}) |> SelectoUpdato.enforce_query(query)

    before = sql(db, "SELECT total_changes()")

    assert {:error, %{details: %{code: :query_rule_not_evaluable}}} =
             SelectoUpdato.execute(operation, target)

    assert sql(db, "SELECT id,quantity FROM items") == [[1, 1]]
    assert sql(db, "SELECT total_changes()") == before
  end

  test "public batch replacement suffix does not execute its safe prefix", %{db: db} do
    tables(
      db,
      "id INTEGER PRIMARY KEY,reference TEXT UNIQUE ON CONFLICT REPLACE,quantity INTEGER",
      "CASCADE"
    )

    sql(db, "CREATE TABLE prefix(id INTEGER PRIMARY KEY,reference TEXT,quantity INTEGER)")

    multi =
      SelectoUpdato.multi()
      |> SelectoUpdato.multi_insert(:first, domain("prefix"), %{
        id: 77,
        reference: "safe",
        quantity: 1
      })
      |> SelectoUpdato.multi_insert(:replace, domain("items"), %{
        id: 2,
        reference: "collision",
        quantity: 2
      })

    before = sql(db, "SELECT total_changes()")

    assert {:error, %{details: %{code: :native_write_effects_not_evaluable}}} =
             SelectoUpdato.run(multi, %Selecto{adapter: Adapter, connection: db})

    assert sql(db, "SELECT * FROM prefix") == []
    assert sql(db, "SELECT id FROM items") == [[1]]
    assert sql(db, "SELECT owner FROM unrelated") == [[1]]
    assert sql(db, "SELECT total_changes()") == before
  end

  for replacement <- [true, false] do
    test "public nested graph replacement=#{replacement} preserves whole-plan admission", %{
      db: db
    } do
      conflict = if unquote(replacement), do: " ON CONFLICT REPLACE", else: ""
      sql(db, "CREATE TABLE orders(id INTEGER PRIMARY KEY,reference TEXT,quantity INTEGER)")

      sql(
        db,
        "CREATE TABLE items(id INTEGER PRIMARY KEY,reference TEXT UNIQUE#{conflict},quantity INTEGER,order_id INTEGER REFERENCES orders(id))"
      )

      sql(db, "CREATE TABLE unrelated(owner INTEGER REFERENCES items(id) ON DELETE CASCADE)")
      sql(db, "INSERT INTO orders VALUES(1,'old',1)")
      sql(db, "INSERT INTO items VALUES(1,'collision',1,1)")
      sql(db, "INSERT INTO unrelated VALUES(1)")

      child =
        domain("items")
        |> put_in([:source, :fields], [:id, :reference, :quantity, :order_id])
        |> put_in([:source, :columns, :order_id], %{type: :integer})

      root =
        domain("orders")
        |> put_in([:writes, :relationships], %{
          items: %{
            writable: true,
            cardinality: :many,
            ownership: :owned,
            allowed_ops: [:insert],
            domain: child,
            child_key: :order_id,
            parent_key: :id,
            strategy: :sync,
            identity_fields: [:id],
            delete_missing: false
          }
        })

      reference = if unquote(replacement), do: "collision", else: "fresh"

      operation =
        root
        |> SelectoUpdato.new()
        |> SelectoUpdato.insert(%{
          id: 2,
          reference: "prefix",
          quantity: 1,
          items: [%{reference: reference, quantity: 2}]
        })

      before = sql(db, "SELECT total_changes()")
      result = SelectoUpdato.execute(operation, %Selecto{adapter: Adapter, connection: db})

      if unquote(replacement) do
        assert {:error, %{details: %{code: :native_write_effects_not_evaluable}}} = result
        assert sql(db, "SELECT id FROM orders") == [[1]]
        assert sql(db, "SELECT id FROM items") == [[1]]
        assert sql(db, "SELECT total_changes()") == before
      else
        assert {:ok, %{operation: :graph, affected_rows: 2}} = result

        assert sql(db, "SELECT reference,order_id FROM items ORDER BY id") == [
                 ["collision", 1],
                 ["fresh", 2]
               ]
      end

      assert sql(db, "SELECT owner FROM unrelated") == [[1]]
    end
  end

  for extra <- [
        ", note TEXT DEFAULT 'ON CONFLICT REPLACE'",
        ", note TEXT DEFAULT 'escaped '' ON CONFLICT REPLACE'",
        ", \"ON CONFLICT REPLACE\" TEXT",
        ", `ON CONFLICT REPLACE` TEXT",
        ", [ON CONFLICT REPLACE] TEXT",
        ", CONSTRAINT \"ON CONFLICT REPLACE\" UNIQUE(reference)",
        " /* ON CONFLICT REPLACE */",
        " -- ON CONFLICT REPLACE\n"
      ] do
    test "public quoted/comment literal positive: #{extra}", %{db: db} do
      tables(
        db,
        "id INTEGER PRIMARY KEY,reference TEXT,quantity INTEGER" <> unquote(extra),
        "CASCADE"
      )

      assert {:ok, %{affected_rows: 1}} =
               SelectoUpdato.execute(
                 operation(%{id: 2, reference: "fresh", quantity: 2}),
                 %Selecto{adapter: Adapter, connection: db}
               )

      assert sql(db, "SELECT id,reference FROM items ORDER BY id") == [
               [1, "collision"],
               [2, "fresh"]
             ]

      assert sql(db, "SELECT owner FROM unrelated") == [[1]]
    end
  end

  test "public refusal preserves the host's transaction", %{db: db} do
    tables(
      db,
      "id INTEGER PRIMARY KEY,reference TEXT UNIQUE ON CONFLICT REPLACE,quantity INTEGER",
      "CASCADE"
    )

    sql(db, "BEGIN")
    sql(db, "UPDATE items SET quantity=3")
    before = sql(db, "SELECT total_changes()")

    assert {:error, %{details: %{code: :native_write_effects_not_evaluable}}} =
             SelectoUpdato.execute(
               operation(%{id: 2, reference: "collision", quantity: 2}),
               %Selecto{adapter: Adapter, connection: db}
             )

    assert sql(db, "SELECT quantity FROM items") == [[3]]
    assert sql(db, "SELECT total_changes()") == before
    sql(db, "ROLLBACK")
    assert sql(db, "SELECT quantity FROM items") == [[1]]

    assert Enum.all?(sql(db, "PRAGMA database_list"), fn [_sequence, _name, file] ->
             file == ""
           end)
  end

  test "ordinary public reads remain available on a replacement-policy table", %{db: db} do
    tables(
      db,
      "id INTEGER PRIMARY KEY,reference TEXT UNIQUE ON CONFLICT REPLACE,quantity INTEGER",
      "CASCADE"
    )

    before = sql(db, "SELECT total_changes()")
    query = domain("items") |> Selecto.configure(db, adapter: Adapter) |> Selecto.select(["id"])
    assert {:ok, _result} = Selecto.execute(query)
    assert sql(db, "SELECT owner FROM unrelated") == [[1]]
    assert sql(db, "SELECT total_changes()") == before
  end

  defp operation(attrs), do: domain("items") |> SelectoUpdato.new() |> SelectoUpdato.insert(attrs)

  defp tables(db, declaration, action) do
    sql(db, "CREATE TABLE items(#{declaration})")

    sql(
      db,
      "CREATE TABLE unrelated(owner INTEGER DEFAULT NULL REFERENCES items(id) ON DELETE #{action})"
    )

    sql(db, "INSERT INTO items(id,reference,quantity) VALUES(1,'collision',1)")
    sql(db, "INSERT INTO unrelated VALUES(1)")
  end

  defp domain(table) do
    %{
      name: table,
      source: %{
        source_table: table,
        primary_key: :id,
        fields: [:id, :reference, :quantity],
        columns: %{
          id: %{type: :integer},
          reference: %{type: :string},
          quantity: %{type: :integer}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{insert: %{enabled: true}},
        fields: %{
          id: %{insertable: true},
          reference: %{insertable: true},
          quantity: %{insertable: true}
        }
      }
    }
  end

  defp sql(db, query) do
    {:ok, result} = Adapter.execute(db, query, [], [])
    result.rows
  end
end
