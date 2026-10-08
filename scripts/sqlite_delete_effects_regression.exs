ExUnit.start()
{:ok, _} = Application.ensure_all_started(:selecto_updato)
{:ok, _} = Application.ensure_all_started(:selecto_db_sqlite)

defmodule SelectoDBSQLite.PublicDeleteEffectsTest do
  use ExUnit.Case, async: true
  alias SelectoDBSQLite.Adapter

  for action <- ["CASCADE", "SET NULL", "SET DEFAULT"] do
    test "public governed UPDATE refuses #{action} with no rule bindings" do
      {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory, foreign_keys: true)
      on_exit(fn -> Adapter.disconnect(db) end)
      sql(db, "CREATE TABLE items(id INTEGER PRIMARY KEY,reference TEXT UNIQUE)")

      sql(
        db,
        "CREATE TABLE children(owner TEXT DEFAULT NULL REFERENCES items(reference) ON UPDATE #{unquote(action)})"
      )

      sql(db, "INSERT INTO items VALUES(1,'ab')")
      sql(db, "INSERT INTO children VALUES('ab')")
      authored = domain()
      authored = put_in(authored, [:source, :fields], [:id, :reference])
      authored = put_in(authored, [:source, :columns, :reference], %{type: :string})
      authored = put_in(authored, [:writes, :operations, :update], %{enabled: true})
      authored = put_in(authored, [:writes, :fields, :reference], %{updatable: true})

      op =
        authored
        |> SelectoUpdato.new()
        |> SelectoUpdato.filter({:id, 1})
        |> SelectoUpdato.update(%{reference: "AB"})

      target = %Selecto{adapter: Adapter, connection: db}
      before = sql(db, "SELECT total_changes()")

      assert {:error, %{details: %{code: :native_write_effects_not_evaluable}}} =
               SelectoUpdato.preview(op, target)

      assert {:error, %{details: %{code: :native_write_effects_not_evaluable}}} =
               SelectoUpdato.execute(op, target)

      assert sql(db, "SELECT * FROM children") == [["ab"]]
      assert sql(db, "SELECT total_changes()") == before
    end

    test "public governed DELETE refuses #{action} with no rule bindings" do
      {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory, foreign_keys: true)
      on_exit(fn -> Adapter.disconnect(db) end)
      sql(db, "CREATE TABLE items(id INTEGER PRIMARY KEY)")

      sql(
        db,
        "CREATE TABLE children(owner INTEGER DEFAULT NULL REFERENCES items(id) ON DELETE #{unquote(action)})"
      )

      sql(db, "INSERT INTO items VALUES(1),(2)")
      sql(db, "INSERT INTO children VALUES(1)")
      target = %Selecto{adapter: Adapter, connection: db}

      op =
        domain()
        |> SelectoUpdato.new()
        |> SelectoUpdato.filter({:id, 1})
        |> SelectoUpdato.delete()

      before = sql(db, "SELECT total_changes()")

      assert {:error, %{details: %{code: :native_write_effects_not_evaluable}}} =
               SelectoUpdato.preview(op, target)

      assert {:error, %{details: %{code: :native_write_effects_not_evaluable}}} =
               SelectoUpdato.execute(op, target)

      assert sql(db, "SELECT * FROM children") == [[1]]
      assert sql(db, "SELECT total_changes()") == before
      safe = %{op | filters: [{:id, 2}]}
      assert {:ok, %{affected_rows: 1}} = SelectoUpdato.execute(safe, target)
      assert sql(db, "SELECT * FROM items") == [[1]]
    end
  end

  defp domain do
    %{
      source: %{
        source_table: "items",
        primary_key: :id,
        fields: [:id],
        columns: %{id: %{type: :integer}},
        associations: %{}
      },
      schemas: %{},
      writes: %{operations: %{delete: %{enabled: true}}, fields: %{}}
    }
  end

  defp sql(db, statement) do
    {:ok, result} = Adapter.execute(db, statement, [], [])
    result.rows
  end
end
