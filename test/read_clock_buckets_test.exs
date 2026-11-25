defmodule SelectoDBSQLite.ReadClockBucketsTest do
  use ExUnit.Case, async: true

  test "date-relative buckets and age counters use the bound clock" do
    domain = %{
      name: "Dates",
      source: %{
        source_table: "dates",
        primary_key: :id,
        fields: [:id, :occurred],
        columns: %{id: %{type: :integer}, occurred: %{type: :naive_datetime}},
        associations: %{},
        redact_fields: []
      },
      schemas: %{},
      joins: %{}
    }

    {:ok, connection} = SelectoDBSQLite.Adapter.connect(database: ":memory:")
    on_exit(fn -> SelectoDBSQLite.Adapter.disconnect(connection) end)

    for sql <- [
          "CREATE TABLE dates(id INTEGER,occurred TEXT)",
          "INSERT INTO dates VALUES(1,'2026-03-15'),(2,'2026-03-14'),(3,'2026-03-01')"
        ] do
      assert {:ok, _} = SelectoDBSQLite.Adapter.execute(connection, sql, [], [])
    end

    base =
      Selecto.configure(
        domain,
        Selecto.Runtime.Context.new(SelectoDBSQLite.Adapter, connection),
        adapter: SelectoDBSQLite.Adapter
      )
      |> Selecto.as_of("2026-03-15")

    selectors = [
      {:bucket, "occurred",
       %{kind: :date_relative_ranges, ranges: [{"today", "today", "ignored"}, {1, 7, "Week"}]}},
      {:count_age_bucket_other, "occurred", "0-7"}
    ]

    for selector <- selectors do
      {sql, params} = base |> Selecto.select([selector]) |> Selecto.to_sql()
      refute sql =~ "CURRENT_"
      assert Enum.any?(params, &(is_binary(&1) and String.starts_with?(&1, "2026-03-15")))
    end

    assert {:ok, {[["Today"], ["Week"], ["Other"]], _, _}} =
             base
             |> Selecto.select([hd(selectors)])
             |> Selecto.order_by(["id"])
             |> Selecto.execute(analyze_complexity: false)

    assert {:ok, {[[1]], _, _}} =
             base
             |> Selecto.select([List.last(selectors)])
             |> Selecto.execute(analyze_complexity: false)
  end
end
