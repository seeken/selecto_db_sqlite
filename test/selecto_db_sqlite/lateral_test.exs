defmodule SelectoDBSQLite.LateralTest do
  use ExUnit.Case, async: false
  alias SelectoDBSQLite.Adapter
  alias Selecto.Expr, as: X

  defp schema(table, columns, opts \\ []) do
    %{
      source_table: table,
      primary_key: :id,
      fields: Map.keys(columns),
      columns: columns,
      associations: %{}
    }
    |> Map.merge(Map.new(opts))
  end

  defp domain(source), do: %{name: "LateralRows", source: source, schemas: %{}, joins: %{}}

  defp root(db, source),
    do:
      Selecto.configure(domain(source), Selecto.Runtime.Context.new(Adapter, db),
        adapter: Adapter
      )

  defp sql(db, statement) do
    assert {:ok, %{rows: rows}} = Adapter.execute(db, statement, [], [])
    rows
  end

  defp rows(query) do
    assert {:ok, {rows, _, _}} = Selecto.execute(query)
    rows
  end

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(db) end)
    sql(db, "CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT, tenant_id INTEGER)")
    sql(db, "CREATE TABLE orders(id INTEGER, person_id INTEGER, state TEXT, tenant_id INTEGER)")
    sql(db, "INSERT INTO people VALUES(1,'Ada',1),(2,'Grace',1),(3,'Renée',1),(4,'Linus',1)")

    sql(
      db,
      "INSERT INTO orders VALUES(101,1,'open',1),(102,1,'closed',1),(103,2,'open',1),(104,NULL,'orphan',1),(105,3,'open',1)"
    )

    people =
      schema("people", %{
        id: %{type: :integer},
        name: %{type: :string},
        tenant_id: %{type: :integer}
      })

    orders =
      schema("orders", %{
        id: %{type: :integer},
        person_id: %{type: :integer},
        state: %{type: :string},
        tenant_id: %{type: :integer}
      })

    assert sql(db, "PRAGMA temp_store") == [[2]]
    assert Enum.all?(sql(db, "PRAGMA database_list"), fn [_, _, file] -> file == "" end)
    %{db: db, people: people, orders: orders}
  end

  defp joined(ctx, type, build) do
    source = fn _parent ->
      root(ctx.db, ctx.orders)
      |> Selecto.select([X.as("id", "order_id")])
      |> Selecto.filter({"person_id", {:ref, "selecto_root.id"}})
      |> build.()
    end

    authored =
      domain(ctx.people)
      |> Map.put(:query_members, %{
        laterals: %{
          child: %{
            source: source,
            join_type: type,
            data_columns: [%{name: "order_id", type: :integer}]
          }
        }
      })

    Selecto.configure(authored, Selecto.Runtime.Context.new(Adapter, ctx.db), adapter: Adapter)
    |> Selecto.with_lateral("child")
    |> Selecto.select(["id", "child.order_id"])
    |> Selecto.order_by(["id", "child.order_id"])
  end

  test "LT001 LEFT rows preserve unmatched roots and a bound OR child predicate", ctx do
    q = joined(ctx, :left, &Selecto.filter(&1, {:or, [{"state", "open"}, {"state", "closed"}]}))
    assert rows(q) == [[1, 101], [1, 102], [2, 103], [3, 105], [4, nil]]
    {statement, params} = Selecto.to_sql(q)
    refute statement =~ "LATERAL"
    assert params == ["open", "closed"]
    assert sql(ctx.db, "PRAGMA query_only") == [[0]]
  end

  test "public direct lateral registers actual stored output names and native column metadata",
       ctx do
    observer = self()

    child = fn _parent ->
      send(observer, :child_built)

      root(ctx.db, ctx.orders)
      |> Selecto.select([X.as("id", "order_id")])
      |> Selecto.filter([
        {"person_id", {:ref, "selecto_root.id"}},
        {:or, [{"state", "open"}, {"state", "closed"}]}
      ])
    end

    base = root(ctx.db, ctx.people)

    q =
      base
      |> Selecto.lateral_join(:left, child, "matched_orders")
      |> Selecto.select(["id", X.as("matched_orders.order_id", "order_id")])
      |> Selecto.filter({"id", {:>, 0}})
      |> Selecto.order_by(["id", "matched_orders.order_id"])

    assert_receive :child_built
    refute_receive :child_built, 0
    assert Selecto.field(q, "matched_orders.order_id").type == :integer
    assert {:ok, {actual, _columns, aliases}} = Selecto.execute(q)
    assert actual == [[1, 101], [1, 102], [2, 103], [3, 105], [4, nil]]
    assert aliases == ["id", "order_id"]
    {statement, params} = Selecto.to_sql(q)

    assert {:ok, %{columns: ["id", "order_id"]}} =
             Adapter.execute_query(ctx.db, statement, params, [])

    assert base.config.columns == root(ctx.db, ctx.people).config.columns
  end

  test "direct with_lateral shares output inference while strict direct policy remains closed",
       ctx do
    child = fn _ ->
      root(ctx.db, ctx.orders)
      |> Selecto.select([X.as("id", "order_id")])
      |> Selecto.filter({"person_id", {:ref, "selecto_root.id"}})
      |> Selecto.order_by([{"id", :desc}])
      |> Selecto.limit(1)
    end

    q =
      root(ctx.db, ctx.people)
      |> Selecto.with_lateral(child, as: "child")
      |> Selecto.select(["id", "child.order_id"])
      |> Selecto.order_by(["id"])

    assert rows(q) == [[1, 102], [2, 103], [3, 105], [4, nil]]

    strict =
      Selecto.configure(domain(ctx.people), Selecto.Runtime.Context.new(Adapter, ctx.db),
        adapter: Adapter,
        mode: :strict
      )

    assert_raise Selecto.PolicyViolation, fn ->
      Selecto.with_lateral(strict, child, as: "child")
    end
  end

  test "inferred metadata never grants hidden, computed or custom SQL output fields", ctx do
    child_source = put_in(ctx.orders, [:columns, :state, :internal], true)

    child = fn _ ->
      root(ctx.db, child_source)
      |> Selecto.select(["state", X.as("id", "order_id")])
      |> Selecto.filter({"person_id", {:ref, "selecto_root.id"}})
    end

    q = root(ctx.db, ctx.people) |> Selecto.lateral_join(:left, child, "child")
    assert Selecto.field(q, "child.order_id").type == :integer
    assert Selecto.field(q, "child.state") == nil
    assert_raise ArgumentError, fn -> Selecto.select(q, ["child.state"]) end

    authored =
      domain(ctx.orders)
      |> Map.put(:custom_columns, %{
        "id" => %{type: :integer, select: "999", requires_join: :selecto_root}
      })

    child = fn _ ->
      Selecto.configure(authored, Selecto.Runtime.Context.new(Adapter, ctx.db), adapter: Adapter)
      |> Selecto.select(["id"])
      |> Selecto.filter({"person_id", {:ref, "selecto_root.id"}})
    end

    q = root(ctx.db, ctx.people) |> Selecto.lateral_join(:left, child, "child")
    assert Selecto.field(q, "child.id") == nil
    assert refusal(q |> Selecto.select(["id"])) =~ "stored field outputs"
  end

  test "LT002 INNER renamed output and bound outer predicate", ctx do
    q =
      joined(ctx, :inner, &Selecto.filter(&1, {"state", "open"}))
      |> Selecto.filter({"id", {:>=, 2}})

    assert rows(q) == [[2, 103], [3, 105]]
    assert elem(Selecto.to_sql(q), 1) == ["open", 2]
  end

  test "QM002 public data query member returns its latest child per parent", ctx do
    authored =
      domain(ctx.people)
      |> Map.put(:schemas, %{order: ctx.orders})
      |> Map.put(:query_members, %{
        laterals: %{
          latest_order: %{
            source: "order",
            query: %{select: ["id"], order_by: [["id", "desc"]], limit: 1},
            correlations: %{"person_id" => "id"},
            join_type: "left"
          }
        }
      })

    q =
      Selecto.configure(authored, Selecto.Runtime.Context.new(Adapter, ctx.db), adapter: Adapter)
      |> Selecto.with_lateral("latest_order")
      |> Selecto.select(["name", "latest_order.id"])
      |> Selecto.order_by(["id"])

    assert rows(q) == [["Ada", 102], ["Grace", 103], ["Renée", 105], ["Linus", nil]]
    {statement, params} = Selecto.to_sql(q)
    assert statement =~ "ROW_NUMBER()"
    assert params == [0, 1]
  end

  test "per-key offset and limit retain duplicates, ties and NULL ordering", ctx do
    sql(
      ctx.db,
      "INSERT INTO orders VALUES(102,1,'closed',1),(106,1,NULL,1),(107,1,'open',1),(108,NULL,'open',1)"
    )

    for {limit, offset} <- [{0, 0}, {1, 0}, {2, 1}, {4, 0}, {nil, 2}] do
      q =
        joined(ctx, :left, fn child ->
          child =
            Selecto.order_by(child, [{"state", :asc_nulls_last}, {"id", :desc}])
            |> Selecto.offset(offset)

          if is_nil(limit), do: child, else: Selecto.limit(child, limit)
        end)

      bounds = " LIMIT " <> to_string(limit || -1) <> " OFFSET " <> to_string(offset)

      reference =
        sql(
          ctx.db,
          "SELECT p.id,(SELECT json_group_array(x.id) FROM (SELECT id FROM orders WHERE person_id=p.id ORDER BY state ASC NULLS LAST,id DESC" <>
            bounds <> ") x) FROM people p ORDER BY p.id"
        )

      expected =
        Enum.flat_map(reference, fn [id, json] ->
          case Jason.decode!(json) do
            [] -> [[id, nil]]
            ids -> Enum.map(ids, &[id, &1])
          end
        end)
        |> Enum.sort()

      assert Enum.sort(rows(q)) == expected
    end

    assert Enum.count(rows(joined(ctx, :inner, &Function.identity/1)), &(&1 == [1, 102])) == 2
  end

  test "duplicate outer keys share the same partition and NULL equals no child", ctx do
    sql(ctx.db, "CREATE TABLE roots(id INTEGER, key INTEGER)")
    sql(ctx.db, "INSERT INTO roots VALUES(1,1),(2,1),(3,NULL),(4,2)")
    people = schema("roots", %{id: %{type: :integer}, key: %{type: :integer}})

    child = fn _ ->
      root(ctx.db, ctx.orders)
      |> Selecto.select([X.as("id", "order_id")])
      |> Selecto.filter({"person_id", {:ref, "selecto_root.key"}})
      |> Selecto.order_by([{"id", :desc}])
      |> Selecto.limit(1)
    end

    q = named_join(ctx.db, people, child, :left)
    assert rows(q) == [[1, 102], [2, 102], [3, nil], [4, 103]]
    assert rows(named_join(ctx.db, people, child, :inner)) == [[1, 102], [2, 102], [4, 103]]
  end

  test "TEXT NOCASE child keys retain their business equality in partition and join", ctx do
    sql(ctx.db, "CREATE TABLE roots(id INTEGER, key TEXT COLLATE BINARY)")
    sql(ctx.db, "CREATE TABLE children(id INTEGER, key TEXT COLLATE NOCASE)")
    sql(ctx.db, "INSERT INTO roots VALUES(1,'A'),(2,'a'),(3,NULL),(4,'B')")
    sql(ctx.db, "INSERT INTO children VALUES(10,'a'),(11,'A'),(12,'b'),(13,NULL)")
    source = schema("roots", %{id: %{type: :integer}, key: %{type: :string}})
    child_source = schema("children", %{id: %{type: :integer}, key: %{type: :string}})

    child = fn _ ->
      root(ctx.db, child_source)
      |> Selecto.select([X.as("id", "order_id")])
      |> Selecto.filter({"key", {:ref, "selecto_root.key"}})
      |> Selecto.order_by([{"id", :desc}])
      |> Selecto.limit(1)
    end

    assert rows(named_join(ctx.db, source, child, :left)) ==
             sql(
               ctx.db,
               "SELECT p.id,(SELECT c.id FROM children c WHERE c.key=p.key ORDER BY c.id DESC LIMIT 1) FROM roots p ORDER BY p.id"
             )

    assert rows(named_join(ctx.db, source, child, :left)) == [[1, 11], [2, 11], [3, nil], [4, 12]]
    sql(ctx.db, "DROP TABLE children")
    sql(ctx.db, "CREATE TABLE children(id INTEGER, key TEXT COLLATE BINARY)")
    sql(ctx.db, "INSERT INTO children VALUES(10,'a'),(11,'A'),(12,'b'),(13,NULL)")

    assert rows(named_join(ctx.db, source, child, :left)) == [
             [1, 11],
             [2, 10],
             [3, nil],
             [4, nil]
           ]
  end

  test "native mismatched affinity refuses instead of splitting a per-parent limit", ctx do
    sql(ctx.db, "CREATE TABLE roots(id INTEGER, key INTEGER)")
    sql(ctx.db, "CREATE TABLE children(id INTEGER, key BLOB)")
    sql(ctx.db, "INSERT INTO roots VALUES(1,1)")
    sql(ctx.db, "INSERT INTO children VALUES(10,1),(11,'1')")

    assert sql(ctx.db, "SELECT id,typeof(key) FROM children ORDER BY id") == [
             [10, "integer"],
             [11, "text"]
           ]

    # This is the actual native counterexample to an unguarded partition lowering.
    assert sql(
             ctx.db,
             "SELECT p.id,(SELECT id FROM children WHERE key=p.key ORDER BY id DESC LIMIT 1) FROM roots p"
           ) == [[1, 11]]

    assert sql(
             ctx.db,
             "SELECT p.id,c.id FROM roots p JOIN(SELECT id,key,row_number()OVER(PARTITION BY key ORDER BY id DESC) n FROM children)c ON c.key=p.key AND c.n=1 ORDER BY c.id"
           ) == [[1, 10], [1, 11]]

    source = schema("roots", %{id: %{type: :integer}, key: %{type: :integer}})
    child_source = schema("children", %{id: %{type: :integer}, key: %{type: :integer}})

    child = fn _ ->
      root(ctx.db, child_source)
      |> Selecto.select([X.as("id", "order_id")])
      |> Selecto.filter({"key", {:ref, "selecto_root.key"}})
      |> Selecto.limit(1)
    end

    {result, calls} =
      native_calls(ctx.db, fn -> refusal(named_join(ctx.db, source, child, :left)) end)

    assert result =~ "equal native"
    assert Enum.any?(calls, &String.starts_with?(&1, "PRAGMA main.table_xinfo"))
    refute Enum.any?(calls, &business_query?/1)
    assert sql(ctx.db, "PRAGMA query_only") == [[0]]
  end

  test "required predicates and carried tenant bounds remain inside every child partition", ctx do
    sql(ctx.db, "INSERT INTO orders VALUES(999,1,'open',2),(998,1,'closed',1)")

    authored =
      domain(Map.put(ctx.people, :tenant_field, :tenant_id))
      |> Map.put(:required_filters, [{"id", {:<=, 3}}])
      |> Map.put(:schemas, %{order: Map.put(ctx.orders, :tenant_field, :tenant_id)})
      |> Map.put(:query_members, %{
        laterals: %{
          latest_order: %{
            source: "order",
            query: %{
              select: ["id"],
              filter: ["eq", "state", "open"],
              order_by: [["id", "desc"]],
              limit: 1
            },
            correlations: %{"person_id" => "id"},
            join_type: "left"
          }
        }
      })

    q =
      Selecto.configure(authored, Selecto.Runtime.Context.new(Adapter, ctx.db), adapter: Adapter)
      |> Selecto.Tenant.require_tenant_filter("tenant_id", 1)
      |> Selecto.with_lateral("latest_order")
      |> Selecto.select(["id", "latest_order.id"])
      |> Selecto.order_by(["id"])

    assert rows(q) == [[1, 101], [2, 103], [3, 105]]
    assert elem(Selecto.to_sql(q), 1) == [1, "open", 0, 1, 3, 1]
    assert q.domain == authored
  end

  test "multiple correlations keep tenant identity separate within each ranked key", ctx do
    sql(ctx.db, "CREATE TABLE roots(id INTEGER,key INTEGER,tenant_id INTEGER)")
    sql(ctx.db, "INSERT INTO roots VALUES(1,1,1),(2,1,2),(3,1,NULL)")
    sql(ctx.db, "INSERT INTO orders VALUES(999,1,'open',2)")

    source =
      schema("roots", %{
        id: %{type: :integer},
        key: %{type: :integer},
        tenant_id: %{type: :integer}
      })

    child = fn _ ->
      root(ctx.db, ctx.orders)
      |> Selecto.select([X.as("id", "order_id")])
      |> Selecto.filter([
        {"person_id", {:ref, "selecto_root.key"}},
        {"tenant_id", {:ref, "selecto_root.tenant_id"}}
      ])
      |> Selecto.order_by([{"id", :desc}])
      |> Selecto.limit(1)
    end

    assert rows(named_join(ctx.db, source, child, :left)) == [[1, 102], [2, 999], [3, nil]]
  end

  test "required child filters retain bound authored strings and source immutability", ctx do
    authored = domain(ctx.orders) |> Map.put(:required_filters, [{"state", "open'); --?"}])

    base =
      Selecto.configure(authored, Selecto.Runtime.Context.new(Adapter, ctx.db), adapter: Adapter)
      |> Selecto.Tenant.require_tenant_filter("tenant_id", 1)

    child = fn _ ->
      base
      |> Selecto.select([X.as("id", "order_id")])
      |> Selecto.filter({"person_id", {:ref, "selecto_root.id"}})
      |> Selecto.limit(1)
    end

    q = named_join(ctx.db, ctx.people, child, :left) |> Selecto.filter({"id", 1})
    assert rows(q) == [[1, nil]]
    {statement, params} = Selecto.to_sql(q)
    refute statement =~ "open'); --?"
    assert params == ["open'); --?", 1, 0, 1, 1]
    assert base.domain == authored
    assert base.set.selected == []
    assert base.set.required_filters == [{"state", "open'); --?"}, {"tenant_id", 1}]
  end

  test "rank fields quote native reserved and mixed-case identifiers", ctx do
    sql(ctx.db, "CREATE TABLE roots(id INTEGER,\"group\" INTEGER)")
    sql(ctx.db, "CREATE TABLE children(id INTEGER,\"group\" INTEGER,\"Order\" INTEGER)")
    sql(ctx.db, "INSERT INTO roots VALUES(1,9),(2,10)")
    sql(ctx.db, "INSERT INTO children VALUES(10,9,1),(11,9,2)")
    source = schema("roots", %{id: %{type: :integer}, group: %{type: :integer}})

    child_source =
      schema("children", %{
        "Order" => %{type: :integer},
        id: %{type: :integer},
        group: %{type: :integer}
      })

    child = fn _ ->
      root(ctx.db, child_source)
      |> Selecto.select([X.as("id", "order_id")])
      |> Selecto.filter({"group", {:ref, "selecto_root.group"}})
      |> Selecto.order_by([{"Order", :desc}])
      |> Selecto.limit(1)
    end

    assert rows(named_join(ctx.db, source, child, :left)) == [[1, 11], [2, nil]]
  end

  test "internal aliases avoid authored output and declared column collisions", ctx do
    sql(ctx.db, "ALTER TABLE orders ADD COLUMN __selecto_lateral_0 INTEGER")

    source =
      put_in(ctx.orders, [:columns, :__selecto_lateral_0], %{type: :integer})
      |> Map.update!(:fields, &[:__selecto_lateral_0 | &1])

    child = fn _ ->
      root(ctx.db, source)
      |> Selecto.select([X.as("id", "__selecto_lateral_1")])
      |> Selecto.filter({"person_id", {:ref, "selecto_root.id"}})
      |> Selecto.order_by([{"id", :desc}])
      |> Selecto.limit(1)
    end

    authored =
      domain(ctx.people)
      |> Map.put(:query_members, %{
        laterals: %{
          child: %{
            source: child,
            join_type: :left,
            data_columns: [%{name: "__selecto_lateral_1", type: :integer}]
          }
        }
      })

    q =
      Selecto.configure(authored, Selecto.Runtime.Context.new(Adapter, ctx.db), adapter: Adapter)
      |> Selecto.with_lateral("child")
      |> Selecto.select(["id", "child.__selecto_lateral_1"])
      |> Selecto.order_by(["id"])

    assert rows(q) == [[1, 102], [2, 103], [3, 105], [4, nil]]
    {statement, _} = Selecto.to_sql(q)
    assert statement =~ "AS __selecto_lateral_2"
    assert statement =~ "AS \"__selecto_lateral_3\""
  end

  test "unsupported structural shapes refuse before any native prepare", ctx do
    builders = [
      &Selecto.filter(&1, {:or, [{"person_id", {:ref, "selecto_root.id"}}, {"state", "open"}]}),
      &Selecto.filter(&1, {"id", {:gt, {:ref, "selecto_root.id"}}}),
      &Selecto.group_by(&1, ["person_id"]),
      &Map.update!(&1, :set, fn set -> Map.put(set, :distinct, true) end),
      &Map.update!(&1, :set, fn set -> Map.put(set, :limit, -1) end),
      &Map.update!(&1, :set, fn set -> Map.put(set, :ctes, []) end)
    ]

    for build <- builders do
      q = joined(ctx, :left, build)
      {message, calls} = native_calls(ctx.db, fn -> refusal(q) end)
      assert message =~ "SQLite lateral"
      assert calls == []
    end

    {message, calls} =
      native_calls(ctx.db, fn -> refusal(joined(ctx, :right, &Function.identity/1)) end)

    assert message =~ "LEFT and INNER"
    assert calls == []
  end

  test "TEMP shadows, virtual sources and native generated fields fail catalog admission", ctx do
    q = joined(ctx, :left, &Selecto.limit(&1, 1))

    sql(
      ctx.db,
      "CREATE TEMP TABLE orders(id INTEGER,person_id INTEGER,state TEXT,tenant_id INTEGER)"
    )

    {message, calls} = native_calls(ctx.db, fn -> refusal(q) end)
    assert message =~ "unshadowed ordinary"
    assert calls != []
    refute Enum.any?(calls, &business_query?/1)
    sql(ctx.db, "DROP TABLE temp.orders")
    sql(ctx.db, "DROP TABLE orders")

    sql(
      ctx.db,
      "CREATE TABLE orders(id INTEGER,person_id INTEGER GENERATED ALWAYS AS(id) STORED,state TEXT,tenant_id INTEGER)"
    )

    assert refusal(q) =~ "equal native"
    sql(ctx.db, "DROP TABLE orders")
    sql(ctx.db, "CREATE VIRTUAL TABLE orders USING rtree(id,person_id,upper)")
    sql(ctx.db, "CREATE TEMP TABLE pragma_table_list(schema TEXT,name TEXT,type TEXT)")
    sql(ctx.db, "INSERT INTO pragma_table_list VALUES('main','orders','table')")
    assert refusal(q) =~ "unshadowed ordinary"
    assert sql(ctx.db, "PRAGMA query_only") == [[0]]
  end

  defp named_join(db, source, child, type) do
    authored =
      domain(source)
      |> Map.put(:query_members, %{
        laterals: %{
          child: %{
            source: child,
            join_type: type,
            data_columns: [%{name: "order_id", type: :integer}]
          }
        }
      })

    Selecto.configure(authored, Selecto.Runtime.Context.new(Adapter, db), adapter: Adapter)
    |> Selecto.with_lateral("child")
    |> Selecto.select(["id", "child.order_id"])
    |> Selecto.order_by(["id", "child.order_id"])
  end

  defp refusal(q) do
    try do
      Selecto.to_sql(q)
      flunk("unsupported SQLite lateral query was admitted")
    rescue
      error in RuntimeError -> Exception.message(error)
    end
  end

  defp business_query?(sql),
    do: String.trim_leading(sql) |> String.starts_with?("select selecto_root")

  defp native_calls(db, callback) do
    :erlang.trace_pattern({Exqlite.Sqlite3, :prepare, 2}, [{:_, [], []}], [])
    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    try do
      task = Task.async(callback)
      result = Task.await(task)
      ref = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^ref}
      {result, collect_calls(db, [])}
    after
      :erlang.trace_pattern({Exqlite.Sqlite3, :prepare, 2}, false, [])
      :erlang.trace(:all, false, [:call])
    end
  end

  defp collect_calls(db, calls) do
    receive do
      {:trace, _, :call, {Exqlite.Sqlite3, :prepare, [^db, sql]}} ->
        collect_calls(db, [sql | calls])

      {:trace, _, :call, _} ->
        collect_calls(db, calls)
    after
      0 -> Enum.reverse(calls)
    end
  end
end
