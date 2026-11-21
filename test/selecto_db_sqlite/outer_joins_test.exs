defmodule SelectoDBSQLite.OuterJoinsTest do
  use ExUnit.Case, async: false

  alias SelectoDBSQLite.Adapter

  defp domain(join) do
    %{
      name: "Orders",
      source: %{
        source_table: "oj_orders",
        primary_key: :id,
        fields: [:id, :customer_id, :region],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          customer_id: %{type: :integer},
          region: %{type: :string}
        },
        associations: %{
          customer: %{
            queryable: :customers,
            field: :customer,
            owner_key: :customer_id,
            related_key: :id,
            where: %{"active" => 1}
          }
        }
      },
      schemas: %{
        customers: %{
          source_table: "oj_customers",
          primary_key: :id,
          fields: [:id, :name, :active],
          redact_fields: [],
          columns: %{id: %{type: :integer}, name: %{type: :string}, active: %{type: :integer}},
          associations: %{}
        }
      },
      joins: %{customer: join}
    }
  end

  @setup [
    "CREATE TABLE oj_orders (id INTEGER PRIMARY KEY, customer_id INTEGER, region VARCHAR(16))",
    "CREATE TABLE oj_customers (id INTEGER PRIMARY KEY, name VARCHAR(16), active INTEGER)",
    "INSERT INTO oj_orders VALUES (1, 1, 'east'), (2, 2, 'east'), (3, NULL, 'west'), (4, 9, 'west')",
    "INSERT INTO oj_customers VALUES (1, 'ann', 1), (2, 'bob', 0), (3, 'cy', 1), (4, 'di', 0)"
  ]

  defp rows(connection, join, opts \\ []) do
    domain =
      join
      |> domain()
      |> Map.merge(Map.new(opts))

    assert {:ok, {rows, _columns, _aliases}} =
             domain
             |> Selecto.configure(connection, adapter: Adapter)
             |> Selecto.select(["id", "customer.name"])
             |> Selecto.execute(analyze_complexity: false)

    rows |> Enum.map(fn row -> Enum.map(row, &integer/1) end) |> Enum.sort()
  end

  setup do
    assert {:ok, conn} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(conn) end)
    for sql <- @setup, do: assert({:ok, _} = Adapter.execute(conn, sql, [], []))
    %{conn: conn}
  end

  test "adapter reports right and full joins (SQLite 3.39+)", %{conn: conn} do
    assert Adapter.supports?(:right_join)
    assert Adapter.supports?(:full_join)
    assert Adapter.supports?(conn, :full_join)
  end

  test "a right join keeps unmatched active customers, never inactive ones", %{conn: conn} do
    assert rows(conn, %{type: :right}) == Enum.sort([[1, "ann"], [nil, "cy"]])
    assert rows(conn, %{type: :right, alias: "buyer_row"}) == Enum.sort([[1, "ann"], [nil, "cy"]])
  end

  test "a full join keeps unmatched rows of both sides", %{conn: conn} do
    assert rows(conn, %{type: :full}) ==
             Enum.sort([[1, "ann"], [2, nil], [3, nil], [4, nil], [nil, "cy"]])
  end

  test "the root's required filter applies after the join", %{conn: conn} do
    assert rows(conn, %{type: :full}, required_filters: [{"region", "east"}]) ==
             [[1, "ann"], [2, nil]]
  end

  defp integer(value), do: value
end
