defmodule SelectoDBSQLite.RollupTest do
  use ExUnit.Case, async: false

  alias Selecto.Expr, as: X
  alias SelectoDBSQLite.Adapter

  setup do
    assert {:ok, connection} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(connection) end)

    execute!(
      connection,
      "CREATE TABLE orders(id INTEGER, person_id INTEGER, state TEXT, amount NUMERIC, tenant_id INTEGER)"
    )

    execute!(connection, "CREATE TABLE people(id INTEGER, name TEXT)")
    execute!(connection, "INSERT INTO people VALUES (1, 'one'), (2, 'two'), (3, 'three')")

    execute!(
      connection,
      "INSERT INTO orders VALUES (1,1,'open',2,7),(2,2,'open',10,7),(3,3,'open',20.5,7),(4,1,'closed',2,7),(5,NULL,'orphan',100,8)"
    )

    base = Selecto.configure(domain(), connection, adapter: Adapter)
    %{connection: connection, base: base}
  end

  test "one dimension produces a total with a distinct GROUPING marker", %{base: base} do
    query = rollup(base, ["state"])

    assert sorted_rows(query) ==
             Enum.sort([[nil, 5, 1], ["closed", 1, 0], ["open", 3, 0], ["orphan", 1, 0]])

    assert {sql, []} = Selecto.to_sql(query)
    refute sql =~ "GROUPING("
    refute sql =~ "rollup("
    assert length(Regex.scan(~r/UNION ALL/, sql)) == 1
  end

  test "two dimensions distinguish an actual NULL detail from its subtotal", %{base: base} do
    query = rollup(base, ["state", "person_id"])

    assert sorted_rows(query) ==
             Enum.sort([
               [nil, nil, 5, 3],
               ["closed", nil, 1, 1],
               ["closed", 1, 1, 0],
               ["open", nil, 3, 1],
               ["open", 1, 1, 0],
               ["open", 2, 1, 0],
               ["open", 3, 1, 0],
               ["orphan", nil, 1, 1],
               ["orphan", nil, 1, 0]
             ])
  end

  test "GROUPING subsets and argument order determine their own bit masks", %{base: base} do
    query =
      base
      |> Selecto.select([
        "state",
        "person_id",
        X.as(X.count(), "n"),
        X.as({:grouping, ["person_id", "state"]}, "reversed"),
        X.as({:grouping, ["person_id"]}, "person_only")
      ])
      |> Selecto.group_by(X.rollup(["state", "person_id"]))

    rows = rows(query)
    assert [nil, nil, 5, 3, 1] in rows
    assert ["open", nil, 3, 2, 1] in rows
    assert ["orphan", nil, 1, 0, 0] in rows
  end

  test "empty input still has one total and preserves aggregate NULL behavior", %{base: base} do
    query =
      base
      |> Selecto.filter({"id", -1})
      |> Selecto.select([
        "state",
        X.as(X.count(), "n"),
        X.as(X.sum("amount"), "sum"),
        X.as(X.coalesce([X.sum("amount"), X.lit(0)]), "default_sum"),
        X.as({:grouping, ["state"]}, "mask")
      ])
      |> Selecto.group_by(X.rollup(["state"]))

    assert rows(query) == [[nil, 0, nil, 0, 1]]
  end

  test "a dimensions-only empty rollup returns its total exactly once", %{base: base} do
    query =
      base
      |> Selecto.filter({"id", -1})
      |> Selecto.select(["state", X.as({:grouping, ["state"]}, "mask")])
      |> Selecto.group_by(X.rollup(["state"]))

    assert rows(query) == [[nil, 1]]
  end

  test "required filters, ordinary filters and their binds stay in every branch", %{
    connection: connection
  } do
    domain = Map.put(domain(), :required_filters, [{"tenant_id", 7}])

    query =
      Selecto.configure(domain, connection, adapter: Adapter, mode: :strict)
      |> Selecto.filter({"state", "open"})
      |> rollup(["state", "person_id"])

    assert [nil, nil, 3, 3] in rows(query)
    assert {_, [7, "open", 7, "open", 7, "open"]} = Selecto.to_sql(query)
    refute Enum.any?(rows(query), &(hd(&1) == "orphan"))
  end

  test "unselected joined dimensions retain INNER JOIN eligibility in the total", %{base: base} do
    query =
      base
      |> Selecto.join(:person, type: :inner)
      |> Selecto.select([X.as(X.count(), "n"), X.as({:grouping, ["person.name"]}, "mask")])
      |> Selecto.group_by(X.rollup(["person.name"]))

    assert sorted_rows(query) == [[1, 0], [1, 0], [2, 0], [4, 1]]
    assert {sql, _, _, joins} = Selecto.Builder.Sql.build_with_joins(query, [])
    assert :person in joins
    assert length(Regex.scan(~r/join\s+"?people/i, sql)) == 2
  end

  test "global decimal ordering and paging use numeric values across all levels", %{base: base} do
    query =
      rollup(base, ["amount"])
      |> Selecto.order_by([{"amount", :asc_nulls_last}])

    assert rows(query) == [[2, 2, 0], [10, 1, 0], [20.5, 1, 0], [100, 1, 0], [nil, 5, 1]]
    assert rows(query |> Selecto.limit(2) |> Selecto.offset(1)) == [[10, 1, 0], [20.5, 1, 0]]
    assert rows(Selecto.offset(query, 3)) == [[100, 1, 0], [nil, 5, 1]]
    assert {_, [2, 1]} = Selecto.to_sql(query |> Selecto.limit(2) |> Selecto.offset(1))
  end

  test "sort directions and aggregate outputs refer to the actual selected position", %{
    base: base
  } do
    query =
      base
      |> Selecto.select([
        "state",
        X.as(X.count(), "order_count"),
        X.as({:grouping, ["state"]}, "mask")
      ])
      |> Selecto.group_by(X.rollup(["state"]))
      |> Selecto.order_by([{X.count(), :desc}, {"state", :asc_nulls_last}])

    assert rows(query) == [[nil, 5, 1], ["open", 3, 0], ["closed", 1, 0], ["orphan", 1, 0]]

    ordered = rows(put_in(query.set.order_by, [{:literal_position, 2}]))
    assert Enum.map(ordered, &Enum.at(&1, 1)) == [1, 1, 3, 5]
  end

  test "CTE markers are structural and scoped to each compound branch", %{base: base} do
    cte_query = fn -> base |> Selecto.select(["id"]) |> Selecto.filter({"tenant_id", 7}) end

    query =
      base
      |> Selecto.with_cte("eligible", cte_query, columns: ["id"])
      |> Selecto.join(:eligible,
        source: "eligible",
        type: :inner,
        owner_key: :id,
        related_key: :id,
        fields: %{"id" => %{type: :integer}}
      )
      |> rollup(["state"])

    assert sorted_rows(query) == Enum.sort([[nil, 4, 1], ["closed", 1, 0], ["open", 3, 0]])
    assert {_, [7, 7]} = Selecto.to_sql(query)
  end

  test "parameterized aggregate inputs retain marker order without placeholder parsing", %{
    base: base
  } do
    query =
      base
      |> Selecto.filter({"tenant_id", 7})
      |> Selecto.select([
        "state",
        X.as(X.sum({:param, 2}), "total"),
        X.as({:grouping, ["state"]}, "mask")
      ])
      |> Selecto.group_by(X.rollup(["state"]))

    assert sorted_rows(query) == Enum.sort([[nil, 8, 1], ["closed", 2, 0], ["open", 6, 0]])
    assert {_, [2, 7, 2, 7]} = Selecto.to_sql(query)
  end

  test "rollup remains composable as a compound operand", %{base: base} do
    left = base |> Selecto.filter({"tenant_id", 7}) |> rollup(["state"])
    right = base |> Selecto.filter({"tenant_id", 8}) |> rollup(["state"])

    assert sorted_rows(Selecto.union(left, right, all: true)) ==
             Enum.sort([
               [nil, 4, 1],
               ["closed", 1, 0],
               ["open", 3, 0],
               [nil, 1, 1],
               ["orphan", 1, 0]
             ])
  end

  test "bounded rollup rejects invalid marker arguments, aliases, grouping and sort shapes", %{
    base: base
  } do
    query = rollup(base, ["state"])

    invalid_sets = [
      %{query.set | group_by: [rollup: ["state", "state"]]},
      %{query.set | group_by: [rollup: List.duplicate("state", 9)]},
      %{query.set | group_by: [{:rollup, ["state"]}, "person_id"]},
      %{query.set | selected: ["state", X.as({:grouping, ["id"]}, "mask")]},
      %{query.set | selected: ["state", X.as({:grouping, ["state", "state"]}, "mask")]},
      %{query.set | selected: [X.as("state", "A"), X.as(X.count(), "a")]},
      %{query.set | selected: ["person_id", X.as(X.count(), "n")]},
      %{query.set | selected: ["state", X.as({:count, "*", {"id", 1}}, "n")]},
      %{query.set | order_by: [{"person_id", :asc}]},
      Map.put(query.set, :window_functions, [%{}])
    ]

    for set <- invalid_sets do
      assert_raise RuntimeError, ~r/Unsupported SQLite rollup/, fn ->
        Selecto.to_sql(%{query | set: set})
      end
    end
  end

  test "connected capabilities report emulated rollup rather than native ROLLUP syntax", %{
    connection: connection
  } do
    assert Adapter.supports?(:rollup)
    assert Adapter.supports?(connection, :rollup)
  end

  test "legacy adapter name delegates the whole-query renderer", %{connection: connection} do
    query =
      Selecto.configure(domain(), connection, adapter: Selecto.DB.SQLite)
      |> rollup(["state"])

    assert [nil, 5, 1] in rows(query)
  end

  defp rollup(base, dimensions) do
    base
    |> Selecto.select(
      dimensions ++
        [X.as(X.count(), "order_count"), X.as({:grouping, dimensions}, "grouping_marker")]
    )
    |> Selecto.group_by(X.rollup(dimensions))
  end

  defp sorted_rows(query), do: query |> rows() |> Enum.sort()

  defp rows(query) do
    assert {:ok, {rows, _, _}} = Selecto.execute(query, analyze_complexity: false)
    rows
  end

  defp execute!(connection, sql), do: assert({:ok, _} = Adapter.execute(connection, sql, [], []))

  defp domain do
    %{
      name: "orders",
      source: %{
        source_table: "orders",
        primary_key: :id,
        fields: [:id, :person_id, :state, :amount, :tenant_id],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          person_id: %{type: :integer},
          state: %{type: :string},
          amount: %{type: :decimal},
          tenant_id: %{type: :integer}
        },
        associations: %{person: %{queryable: :people, owner_key: :person_id, related_key: :id}}
      },
      schemas: %{
        people: %{
          source_table: "people",
          primary_key: :id,
          fields: [:id, :name],
          redact_fields: [],
          columns: %{id: %{type: :integer}, name: %{type: :string}},
          associations: %{}
        }
      },
      joins: %{person: %{type: :inner}}
    }
  end
end
