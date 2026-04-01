defmodule SelectoDBSQLite.UpdatoAdapterTest do
  use ExUnit.Case, async: true

  alias SelectoUpdato.Error

  defmodule Item do
    use Ecto.Schema
    import Ecto.Changeset

    schema "items" do
      field(:sku, :string)
      field(:name, :string)
    end

    def changeset(item, attrs) do
      item
      |> cast(attrs, [:sku, :name])
      |> validate_required([:sku, :name])
    end
  end

  defmodule FakeSQLiteRepo do
    def __adapter__, do: Ecto.Adapters.SQLite3

    def seed(records), do: Process.put(:fake_sqlite_repo_records, records)
    def one(_query), do: List.first(records())
    def insert(%Ecto.Changeset{valid?: false} = changeset, _opts), do: {:error, changeset}

    def insert(%Ecto.Changeset{} = changeset, opts) do
      send(self(), {:repo_insert_opts, opts})

      record = Ecto.Changeset.apply_changes(changeset)

      returned =
        if opts[:on_conflict] == :nothing do
          Map.put(record, :id, nil)
        else
          Map.put(record, :id, 1)
        end

      {:ok, returned}
    end

    def insert_all(schema, records, opts) do
      send(self(), {:repo_insert_all_opts, schema, records, opts})
      {length(records), nil}
    end

    defp records, do: Process.get(:fake_sqlite_repo_records, [])
  end

  setup do
    FakeSQLiteRepo.seed([%Item{id: 1, sku: "SKU-1", name: "Old"}])
    :ok
  end

  test "sqlite upsert keeps explicit column conflict target and on_conflict action" do
    op =
      SelectoUpdato.new(domain())
      |> SelectoUpdato.upsert(%{sku: "SKU-1", name: "Widget"})
      |> SelectoUpdato.conflict_target(["sku"])
      |> SelectoUpdato.on_conflict({:replace, [:name]})

    assert {:ok, %Item{id: 1}} = SelectoUpdato.execute(op, FakeSQLiteRepo)
    assert_received {:repo_insert_opts, opts}
    assert opts[:conflict_target] == [:sku]
    assert opts[:on_conflict] == {:replace, [:name]}
  end

  test "sqlite upsert_all keeps sqlite-safe conflict target and on_conflict action" do
    op =
      SelectoUpdato.new(domain())
      |> SelectoUpdato.upsert_all([%{sku: "SKU-1", name: "Widget"}])
      |> SelectoUpdato.conflict_target(["sku"])
      |> SelectoUpdato.on_conflict(:replace_all_except_primary_key)

    assert {:ok, %{upserted: 1}} = SelectoUpdato.execute(op, FakeSQLiteRepo)

    assert_received {:repo_insert_all_opts, Item, [%{name: "Widget", sku: "SKU-1"}], opts}
    assert opts[:conflict_target] == [:sku]
    assert opts[:on_conflict] == {:replace_all_except, [:id]}
  end

  test "sqlite upsert rejects named constraint conflict targets" do
    op =
      SelectoUpdato.new(domain())
      |> SelectoUpdato.upsert(%{sku: "SKU-1", name: "Widget"})
      |> SelectoUpdato.conflict_target({:constraint, :items_sku_index})
      |> SelectoUpdato.on_conflict(:replace_all)

    assert {:error, %Error{type: :invalid_operation} = error} =
             SelectoUpdato.execute(op, FakeSQLiteRepo)

    assert error.message =~ "named constraint conflict targets"
  end

  test "sqlite upsert with do nothing reloads the existing row when sqlite returns nil primary key" do
    op =
      SelectoUpdato.new(domain())
      |> SelectoUpdato.upsert(%{sku: "SKU-1", name: "Ignored"})
      |> SelectoUpdato.conflict_target(["sku"])
      |> SelectoUpdato.on_conflict(:nothing)

    assert {:ok, %Item{id: 1, sku: "SKU-1", name: "Old"}} =
             SelectoUpdato.execute(op, FakeSQLiteRepo)
  end

  test "sqlite sql preview uses on conflict syntax" do
    sql =
      SelectoUpdato.new(domain(), adapter: :sqlite)
      |> SelectoUpdato.upsert(%{sku: "SKU-1", name: "Widget"})
      |> SelectoUpdato.conflict_target(["sku"])
      |> SelectoUpdato.on_conflict({:replace, [:name]})
      |> SelectoUpdato.to_sql()

    assert sql =~ "INSERT INTO items"
    assert sql =~ "ON CONFLICT (sku) DO UPDATE SET"
    assert sql =~ "name = EXCLUDED.name"
  end

  defp domain do
    %{
      source: Item,
      primary_key: "id",
      columns: %{
        "id" => %{type: :integer},
        "sku" => %{type: :string},
        "name" => %{type: :string}
      },
      readonly: ["id"],
      required_on_insert: ["sku", "name"]
    }
  end
end
