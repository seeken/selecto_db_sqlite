# Public Updato proof; load selected dependencies before executing this script.
ExUnit.start()
{:ok, _} = Application.ensure_all_started(:selecto_updato)
{:ok, _} = Application.ensure_all_started(:selecto_db_sqlite)

defmodule SelectoDBSQLite.NativeIncomingFKTest do
  use ExUnit.Case, async: true
  alias SelectoDBSQLite.Adapter

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory, foreign_keys: true)
    on_exit(fn -> Adapter.disconnect(db) end)
    %{db: db}
  end

  test "candidate empty_to_null persists null once", %{db: db} do
    sql(db, "CREATE TABLE items(id INTEGER PRIMARY KEY,reference TEXT,quantity INTEGER)")
    authored = domain(%{op: "value.eq", value: nil}, [%{op: "text.empty_to_null"}], :insert)

    result =
      authored
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{reference: "", quantity: 1})
      |> SelectoUpdato.execute(%Selecto{adapter: Adapter, connection: db})

    IO.inspect(result, label: "native candidate empty_to_null")
    assert {:ok, _} = result
    assert sql(db, "SELECT reference,quantity FROM items") == [[nil, 1]]
  end

  for action <- ["CASCADE", "SET NULL", "SET DEFAULT"], assigned <- [false, true] do
    test "public #{action} refuses original-assignment=#{assigned} before business DML", %{db: db} do
      tables(db, unquote(action))
      changes = if unquote(assigned), do: %{reference: "AB", quantity: 3}, else: %{quantity: 3}
      op = operation(changes)
      target = %Selecto{adapter: Adapter, connection: db}

      for result <- [SelectoUpdato.execute(op, target), SelectoUpdato.preview(op, target)] do
        assert {:error, %{details: %{code: :native_write_effects_not_evaluable}}} = result
      end

      assert sql(db, "SELECT reference,quantity FROM items") == [["ab", 1]]
      assert sql(db, "SELECT * FROM unrelated") == [["ab"]]
      assert sql(db, "SELECT name FROM temp.sqlite_master") == []
      # Storage projection writes rollback-only private TEMP rows; total_changes
      # includes them. Native adapter tests separately prove zero DML from the
      # final prepared command whose catalog admission fails.
    end
  end

  test "public normalizer refusal preserves pending caller work", %{db: db} do
    tables(db, "CASCADE")
    sql(db, "BEGIN")
    sql(db, "UPDATE items SET quantity=2 WHERE id=1")

    assert {:error, %{details: %{code: :native_write_effects_not_evaluable}}} =
             SelectoUpdato.execute(operation(%{quantity: 3}), %Selecto{
               adapter: Adapter,
               connection: db
             })

    assert sql(db, "SELECT reference,quantity FROM items") == [["ab", 2]]
    assert sql(db, "SELECT owner FROM unrelated") == [["ab"]]
    sql(db, "ROLLBACK")
    assert sql(db, "SELECT reference,quantity FROM items") == [["ab", 1]]
  end

  for action <- ["CASCADE", "SET NULL", "SET DEFAULT"] do
    test "unchanged public normalizer retains unrelated #{action} edge", %{db: db} do
      tables(db, unquote(action), "AB")

      assert {:ok, _} =
               SelectoUpdato.execute(operation(%{quantity: 3}), %Selecto{
                 adapter: Adapter,
                 connection: db
               })

      assert sql(db, "SELECT reference,quantity FROM items") == [["AB", 3]]
      assert sql(db, "SELECT owner FROM unrelated") == [["AB"]]
    end
  end

  for action <- ["NO ACTION", "RESTRICT"] do
    test "public normalization preserves nonautomatic #{action} semantics", %{db: db} do
      tables(db, unquote(action))
      sql(db, "DELETE FROM unrelated")

      assert {:ok, _} =
               SelectoUpdato.execute(operation(%{quantity: 3}), %Selecto{
                 adapter: Adapter,
                 connection: db
               })

      assert sql(db, "SELECT reference,quantity FROM items") == [["AB", 3]]
    end
  end

  defp operation(changes) do
    domain(
      %{op: "value.eq", value: "AB"},
      [%{op: "text.uppercase", profile: "ascii_v1"}],
      :update
    )
    |> SelectoUpdato.new()
    |> SelectoUpdato.update(changes)
    |> SelectoUpdato.filter({:id, 1})
  end

  defp tables(db, action, value \\ "ab") do
    sql(db, "CREATE TABLE items(id INTEGER PRIMARY KEY,reference TEXT UNIQUE,quantity INTEGER)")

    sql(
      db,
      "CREATE TABLE unrelated(owner TEXT DEFAULT NULL REFERENCES items(reference) ON UPDATE #{action})"
    )

    sql(db, "INSERT INTO items VALUES(1,'#{value}',1)")
    sql(db, "INSERT INTO unrelated VALUES('#{value}')")
  end

  defp domain(test, steps, operation) do
    %{
      name: "Storage probe",
      source: %{
        source_table: "items",
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
        operations: %{operation => %{enabled: true}},
        fields: %{
          reference: %{insertable: true, updatable: true},
          quantity: %{insertable: true, updatable: true}
        }
      },
      rules: %{
        schema: "selecto.data_rules.v1",
        definitions: %{r: %{version: 1, test: test}},
        normalizers: %{n: %{version: 1, steps: steps}},
        bindings: %{
          r: %{
            subject: %{scope: :candidate, path: [:reference]},
            operations: [operation],
            rule: %{id: :r, version: 1},
            normalizer: %{id: :n, version: 1}
          }
        }
      }
    }
  end

  defp sql(db, statement) do
    {:ok, result} = Adapter.execute(db, statement, [], [])
    result.rows
  end
end
