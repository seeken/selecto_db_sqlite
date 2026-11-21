defmodule SelectoDBSQLite.GroupingSetsTest do
  use ExUnit.Case, async: false

  alias Selecto.Expr, as: X
  alias SelectoDBSQLite.Adapter

  setup do
    assert {:ok, connection} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(connection) end)

    execute!(
      connection,
      "CREATE TABLE sales(id INTEGER PRIMARY KEY, region TEXT, channel TEXT, tier INTEGER, amount INTEGER)"
    )

    execute!(
      connection,
      "INSERT INTO sales VALUES (1,'east','web',1,10),(2,'east','web',2,20),(3,'east','store',1,5)," <>
        "(4,'west','web',1,7),(5,'west',NULL,2,3),(6,NULL,'store',1,40)"
    )

    %{base: Selecto.configure(domain(), connection, adapter: Adapter)}
  end

  test "a cube is one branch per subset, telling NULL keys from subtotals", %{base: base} do
    query =
      base |> measures(["region", "channel"]) |> Selecto.group_by(X.cube(["region", "channel"]))

    assert sorted_rows(query) ==
             Enum.sort([
               ["east", "web", 2, 30, 0],
               ["east", "store", 1, 5, 0],
               ["west", "web", 1, 7, 0],
               ["west", nil, 1, 3, 0],
               [nil, "store", 1, 40, 0],
               ["east", nil, 3, 35, 1],
               ["west", nil, 2, 10, 1],
               [nil, nil, 1, 40, 1],
               [nil, "web", 3, 37, 2],
               [nil, "store", 2, 45, 2],
               [nil, nil, 1, 3, 2],
               [nil, nil, 6, 85, 3]
             ])

    assert {sql, []} = Selecto.to_sql(query)
    assert length(Regex.scan(~r/UNION ALL/, sql)) == 3
    refute sql =~ ~r/CUBE|GROUPING/
  end

  test "declared grouping sets, the grand total and filters in every branch", %{base: base} do
    query =
      base
      |> Selecto.filter({"channel", "web"})
      |> measures(["region", "channel"])
      |> Selecto.group_by(X.grouping_sets([["channel"], ["region", "channel"], []]))

    assert sorted_rows(query) ==
             Enum.sort([
               [nil, "web", 3, 37, 2],
               ["east", "web", 2, 30, 0],
               ["west", "web", 1, 7, 0],
               [nil, nil, 3, 37, 3]
             ])
  end

  test "orderings and limits apply to the whole union", %{base: base} do
    query =
      base
      |> measures(["region", "channel"])
      |> Selecto.group_by(X.grouping_sets([["region"], ["channel"], []]))
      |> Selecto.order_by([{{:grouping, ["region", "channel"]}, :asc}, {{:sum, "amount"}, :desc}])
      |> Selecto.limit(4)

    assert rows(query) == [
             [nil, nil, 1, 40, 1],
             ["east", nil, 3, 35, 1],
             ["west", nil, 2, 10, 1],
             [nil, "store", 2, 45, 2]
           ]
  end

  test "an unselected ordering refuses before SQL", %{base: base} do
    query =
      base
      |> measures(["region", "channel"])
      |> Selecto.group_by(X.cube(["region", "channel"]))
      |> Selecto.order_by({"id", :asc})

    assert {:error, %Selecto.Error{details: %{reason: :ordering_not_selected}}} =
             Selecto.execute(query)
  end

  test "a five-dimension cube is one branch per subset", %{base: base} do
    dimensions = ["region", "channel", "tier", "amount", "id"]

    query =
      base
      |> Selecto.select([X.as(X.count(), "n")])
      |> Selecto.group_by(X.cube(dimensions))

    assert %{sets: sets} = Selecto.grouping_set_positions(query)
    assert length(sets) == 32
    # 1 + 6 rows per non-empty subset that includes id; the id column is unique
    assert length(rows(query)) == 1 + Enum.sum(for set <- sets, set != [], do: rows_for(set))
  end

  test "capabilities report cube and grouping sets", %{base: base} do
    connection = Selecto.Runtime.Context.connection(base)
    assert Adapter.supports?(connection, :cube)
    assert Adapter.supports?(connection, :grouping_sets)
    assert Selecto.DB.SQLite.supports?(:cube)
  end

  # Distinct key combinations of each set over the fixture.
  defp rows_for(set) do
    data = [
      {"east", "web", 1, 10, 1},
      {"east", "web", 2, 20, 2},
      {"east", "store", 1, 5, 3},
      {"west", "web", 1, 7, 4},
      {"west", nil, 2, 3, 5},
      {nil, "store", 1, 40, 6}
    ]

    data |> Enum.map(fn row -> Enum.map(set, &elem(row, &1)) end) |> Enum.uniq() |> length()
  end

  defp measures(query, dimensions) do
    Selecto.select(
      query,
      dimensions ++
        [
          X.as(X.count(), "n"),
          X.as(X.sum("amount"), "total"),
          X.as({:grouping, dimensions}, "marker")
        ]
    )
  end

  defp sorted_rows(query), do: query |> rows() |> Enum.sort()

  defp rows(query) do
    assert {:ok, {rows, _columns, _aliases}} = Selecto.execute(query)
    rows
  end

  defp execute!(connection, sql), do: assert({:ok, _} = Adapter.execute(connection, sql, [], []))

  defp domain do
    %{
      name: "sales",
      source: %{
        source_table: "sales",
        primary_key: :id,
        fields: [:id, :region, :channel, :tier, :amount],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          region: %{type: :string},
          channel: %{type: :string},
          tier: %{type: :integer},
          amount: %{type: :integer}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end
end
