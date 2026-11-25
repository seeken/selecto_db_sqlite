defmodule SelectoDBSQLite.CoreFixesTest do
  use ExUnit.Case, async: false
  alias SelectoDBSQLite.Adapter

  setup do
    {:ok, conn} = Adapter.connect(database: ":memory:")
    on_exit(fn -> Adapter.disconnect(conn) end)
    %{conn: conn}
  end

  defp sql!(conn, sql) do
    assert {:ok, _} = Adapter.execute(conn, sql, [], [])
  end

  defp domain(type, extra \\ %{}) do
    %{
      name: "Clock fixes",
      source: %{
        source_table: "fix_events",
        primary_key: :id,
        fields: [:id, :at, :age],
        associations: %{},
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          at: Map.merge(%{type: type}, extra),
          age: %{
            type: :integer,
            computed: %{kind: :expression, expression: ["days_between", ["field", "at"], ["now"]]}
          }
        }
      },
      schemas: %{},
      joins: %{}
    }
  end

  defp base(conn, domain) do
    Selecto.configure(domain, Selecto.Runtime.Context.new(Adapter, conn), adapter: Adapter)
  end

  defp rows(query) do
    assert {:ok, {rows, _, _}} = Selecto.execute(query, analyze_complexity: false)
    rows
  end

  test "query date agrees across shortcut, computed age and relative buckets", %{conn: conn} do
    sql!(conn, "CREATE TEMP TABLE fix_events(id INTEGER, at DATE)")
    sql!(conn, "INSERT INTO fix_events VALUES(1,'2026-03-15'),(2,'2026-03-14')")

    for {clock, zone} <- [
          {"2026-03-15", "Asia/Tokyo"},
          {"2026-03-15T20:00:00-06:00", "America/Denver"}
        ] do
      q = base(conn, domain(:date)) |> Selecto.as_of(clock) |> Selecto.timezone(zone)

      assert rows(q |> Selecto.select(["id", "age"]) |> Selecto.order_by(["id"])) == [
               [1, 0],
               [2, 1]
             ]

      assert rows(
               q
               |> Selecto.select(["id"])
               |> Selecto.filter([Selecto.Expr.date_shortcut("at", "today")])
             ) == [[1]]

      for kind <- [:elapsed_days_ranges, :date_relative_ranges] do
        ranges =
          if kind == :date_relative_ranges,
            do: [{"today", "today", "x"}, {"yesterday", "yesterday", "y"}],
            else: [{0, 0, "Today"}, {1, 1, "Yesterday"}]

        assert rows(
                 q
                 |> Selecto.select(["id", {:bucket, "at", %{kind: kind, ranges: ranges}}])
                 |> Selecto.order_by(["id"])
               ) == [[1, "Today"], [2, "Yesterday"]]
      end

      assert rows(q |> Selecto.select([{:count_age_bucket, "at", 0, 0}])) == [[1]]
    end
  end

  test "instant periods retain both half-open boundaries", %{conn: conn} do
    sql!(conn, "CREATE TABLE fix_events(id INTEGER, at TEXT)")

    sql!(
      conn,
      "INSERT INTO fix_events VALUES(1,'2026-03-15 00:00:00'),(2,'2026-03-15 12:00:00'),(3,'2026-03-16 00:00:00')"
    )

    q =
      base(conn, domain(:utc_datetime))
      |> Selecto.timezone("Etc/UTC")
      |> Selecto.as_of("2026-03-15")
      |> Selecto.select(["id"])
      |> Selecto.order_by(["id"])

    for p <- [Selecto.Expr.on("at", "2026-03-15"), Selecto.Expr.date_shortcut("at", "today")] do
      assert rows(Selecto.filter(q, [p])) == [[1], [2]]
    end
  end

  test "NOT of a DST gap preserves NULL", %{conn: conn} do
    sql!(conn, "CREATE TABLE fix_events(id INTEGER, at TEXT)")
    sql!(conn, "INSERT INTO fix_events VALUES(1,NULL),(2,'2026-03-08 09:30:00')")

    q =
      base(conn, domain(:utc_datetime))
      |> Selecto.timezone("America/Denver")
      |> Selecto.select(["id"])
      |> Selecto.filter([{:not, Selecto.Expr.on("at", "2026-03-08T02:30")}])

    assert rows(q) == [[2]]
  end

  test "month buckets and now use the query-zone day across UTC month boundaries", %{conn: conn} do
    sql!(conn, "CREATE TEMP TABLE fix_events(id INTEGER, at DATE)")
    sql!(conn, "INSERT INTO fix_events VALUES(1,'2026-03-01'),(2,'2026-02-28')")

    for {clock, zone, expected} <- [
          {"2026-03-01", "Asia/Tokyo", [[1, "This"], [2, "Previous"]]},
          {"2026-02-28T22:00:00-07:00", "America/Denver", [[1, "Other"], [2, "This"]]}
        ] do
      q = base(conn, domain(:date)) |> Selecto.as_of(clock) |> Selecto.timezone(zone)

      assert rows(
               q
               |> Selecto.select([
                 "id",
                 {:bucket, "at",
                  %{kind: :month_ranges, ranges: [{0, 0, "This"}, {1, 1, "Previous"}]}}
               ])
               |> Selecto.order_by(["id"])
             ) == expected

      # Exercise the standalone now node independently from days_between.
      {sql, _, params} =
        Selecto.gen_sql(q |> Selecto.select([{:computed_value, ["cast", ["now"], "date"]}]), [])

      assert sql != ""
      assert Enum.all?(params, &String.starts_with?(&1, String.slice(clock, 0, 10)))
    end
  end

  test "standalone temporal fallback retains localized now time", %{conn: conn} do
    sql!(conn, "CREATE TABLE fix_events(id INTEGER, at TEXT)")
    sql!(conn, "INSERT INTO fix_events VALUES(1,NULL)")

    q =
      base(conn, domain(:naive_datetime))
      |> Selecto.as_of("2026-03-15T20:15:00-06:00")
      |> Selecto.timezone("America/Denver")
      |> Selecto.select([{:computed_value, ["temporal_coalesce", ["field", "at"], ["now"]]}])

    assert rows(q) == [["2026-03-15T20:15:00"]]
  end
end
