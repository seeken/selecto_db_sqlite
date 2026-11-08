defmodule SelectoDBSQLite.NameRuleTest do
  use ExUnit.Case, async: false

  @adapter SelectoDBSQLite.Adapter

  setup do
    {:ok, conn} = @adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> @adapter.disconnect(conn) end)

    for sql <- [
          "CREATE TABLE p (id INT PRIMARY KEY, name VARCHAR(20), tenant_id INT)",
          "CREATE TABLE r (id INT PRIMARY KEY, product_id INT, rating INT, title VARCHAR(20), tenant_id INT)",
          "CREATE TABLE lk (product_id INT, label VARCHAR(20))",
          "INSERT INTO p VALUES (1, 'a', 1), (2, 'b', 2)",
          "INSERT INTO r VALUES (1, 1, 5, 'pub-t1', 1), (2, 1, 5, 'pub-t2', 2), (3, 2, 1, 'pub-low', 2)",
          "INSERT INTO lk VALUES (1, 'TBL-LK')"
        ],
        do: {:ok, _} = @adapter.execute(conn, sql, [], [])

    %{conn: conn, t: %{p: "p", r: "r", lk: "lk"}}
  end

  # Shared shapes: filter subqueries, declared non-association joins, domains
  # rooted on a CTE, and lists private to union members.

  defp dom(table, fields, extra \\ %{}) do
    %{
      name: table,
      schemas: %{},
      joins: %{},
      source:
        Map.merge(
          %{
            source_table: table,
            primary_key: :id,
            fields: Keyword.keys(fields),
            redact_fields: [],
            columns: Map.new(fields, fn {k, v} -> {k, %{type: v}} end),
            associations: %{}
          },
          extra
        )
    }
  end

  @pf [id: :integer, name: :string, tenant_id: :integer]
  @rf [id: :integer, product_id: :integer, rating: :integer, title: :string, tenant_id: :integer]

  defp p(ctx), do: dom(ctx.t.p, @pf)
  defp r(ctx), do: dom(ctx.t.r, @rf)
  defp q(ctx, domain), do: Selecto.configure(domain, ctx.conn, adapter: @adapter, validate: false)

  defp outcome(query) do
    case Selecto.execute(query) do
      {:ok, {rows, _, _}} -> Enum.sort(rows)
      {:error, %Selecto.Error{type: type, details: details}} -> {:error, details[:reason] || type}
    end
  end

  defp refusal(query) do
    case Selecto.execute(query) do
      {:error, %Selecto.Error{details: %{reason: reason, relations: names}}} -> {reason, names}
      other -> other
    end
  end

  # Products with a review rated 4 or more: only product 1.
  defp rated(ctx),
    do: q(ctx, r(ctx)) |> Selecto.select(["product_id"]) |> Selecto.filter({"rating", {:>=, 4}})

  defp values_r(query, ctx),
    do:
      Selecto.with_values(query, [[2, 5, 99, "VALS", 1]],
        columns: ["product_id", "rating", "id", "title", "tenant_id"],
        as: ctx.t.r
      )

  test "a filter subquery reads its table; a list named like it refuses", ctx do
    in_filter = q(ctx, p(ctx)) |> Selecto.filter({"id", {:subquery, :in, rated(ctx)}})
    assert outcome(Selecto.select(in_filter, ["name"])) == [["a"]]

    assert refusal(in_filter |> values_r(ctx) |> Selecto.select(["name"])) ==
             {:cte_name_collision, [ctx.t.r]}

    exists =
      q(ctx, r(ctx))
      |> Selecto.select(["id"])
      |> Selecto.filter({"product_id", 2})
      |> Selecto.filter({"rating", {:>=, 4}})

    exists_query = q(ctx, p(ctx)) |> Selecto.filter({:exists, exists})
    assert outcome(Selecto.select(exists_query, ["name"])) == []

    assert refusal(exists_query |> values_r(ctx) |> Selecto.select(["name"])) ==
             {:cte_name_collision, [ctx.t.r]}

    any =
      q(ctx, p(ctx))
      |> values_r(ctx)
      |> Selecto.filter({"id", "=", {:subquery, :any, rated(ctx)}})
      |> Selecto.select(["name"])

    assert refusal(any) == {:cte_name_collision, [ctx.t.r]}
  end

  test "a declared non-association join reads its table; a list named like it refuses", ctx do
    domain =
      put_in(p(ctx), [:joins], %{
        lkd: %{
          non_assoc: true,
          source: ctx.t.lk,
          name: "lkd",
          type: :left,
          owner_key: :id,
          related_key: :product_id,
          fields: %{"label" => %{type: :string}}
        }
      })

    query = q(ctx, domain) |> Selecto.select(["name", "lkd.label"])
    assert outcome(query) == [["a", "TBL-LK"], ["b", nil]]

    named =
      Selecto.with_values(query, [[1, "OUTER-V"]], columns: ["product_id", "label"], as: ctx.t.lk)

    assert refusal(named) == {:cte_name_collision, [ctx.t.lk]}
  end

  test "a domain rooted on a CTE reads the CTE", ctx do
    one = fn -> q(ctx, p(ctx)) |> Selecto.select(["id", "name"]) |> Selecto.filter({"id", 1}) end
    c1 = dom("cte_one", id: :integer, name: :string)
    c2 = dom("cte_two", id: :integer, name: :string)

    rooted = q(ctx, c1) |> Selecto.with_cte("cte_one", one, columns: ["id", "name"])
    assert outcome(Selecto.select(rooted, ["name"])) == [["a"]]

    chained =
      q(ctx, c2)
      |> Selecto.with_cte("cte_one", one, columns: ["id", "name"])
      |> Selecto.with_cte("cte_two", fn -> q(ctx, c1) |> Selecto.select(["id", "name"]) end,
        columns: ["id", "name"],
        dependencies: ["cte_one"]
      )

    assert outcome(Selecto.select(chained, ["name"])) == [["a"]]

    # The same name read as a table elsewhere in the statement still refuses.
    as_table = dom(ctx.t.lk, product_id: :integer, label: :string)
    lk_rows = fn -> q(ctx, p(ctx)) |> Selecto.select(["id", "name"]) end

    mixed =
      q(ctx, dom(ctx.t.lk, id: :integer, name: :string))
      |> Selecto.with_cte(
        "cb",
        fn -> q(ctx, as_table) |> Selecto.select(["product_id", "label"]) end,
        columns: ["pid", "plabel"]
      )
      |> Selecto.with_cte(ctx.t.lk, lk_rows, columns: ["id", "name"])
      |> Selecto.select(["name"])

    assert refusal(mixed) == {:cte_name_collision, [ctx.t.lk]}
  end

  defp labelled(ctx, label) do
    q(ctx, p(ctx))
    |> Selecto.with_values([[1, label]], columns: ["product_id", "label"], as: "vv")
    |> Selecto.join(:vj,
      source: "vv",
      type: :left,
      owner_key: :id,
      related_key: :product_id,
      fields: %{"label" => %{type: :string}}
    )
    |> Selecto.select(["name", "vj.label"])
  end

  test "different lists of one name in two union members are private to each", ctx do
    union = Selecto.union(labelled(ctx, "L"), labelled(ctx, "R"), all: true)
    assert outcome(union) == [["a", "L"], ["a", "R"], ["b", nil], ["b", nil]]

    # A member's list and a different statement list of that name refuse.
    body = fn -> Selecto.union(labelled(ctx, "L"), labelled(ctx, "L"), all: true) end

    statement =
      q(ctx, p(ctx))
      |> Selecto.with_values([[2, "MAIN"]], columns: ["product_id", "label"], as: "vv")
      |> Selecto.with_cte("cb", body, columns: ["cname", "clab"])
      |> Selecto.select(["name"])

    assert refusal(statement) == {:cte_name_redefined, ["vv"]}
  end
end
