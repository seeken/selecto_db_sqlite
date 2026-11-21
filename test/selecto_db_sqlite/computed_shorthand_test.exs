defmodule SelectoDBSQLite.ComputedShorthandTest do
  use ExUnit.Case, async: false

  alias Selecto.Dialect.Bucket.Expression, as: BucketExpression
  alias Selecto.Dialect.ComputedValue
  alias Selecto.Expr, as: X
  alias SelectoDBSQLite.{Adapter, Dialect}

  # temporal_delta, bucket and days_between on text-stored dates and
  # datetimes, and month_ranges buckets (calendar months ago).

  setup do
    assert {:ok, connection} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(connection) end)
    %{connection: connection}
  end

  describe "computed shorthand" do
    setup %{connection: connection} do
      execute!(
        connection,
        "CREATE TABLE events (id INTEGER PRIMARY KEY, name TEXT, starts_on TEXT)"
      )

      execute!(
        connection,
        "CREATE TABLE tickets (id INTEGER PRIMARY KEY, event_id INTEGER, purchased_at TEXT, refunded_on TEXT)"
      )

      execute!(
        connection,
        "INSERT INTO events VALUES (1, 'Gala', '2026-06-30'), (2, 'Fair', NULL)"
      )

      execute!(connection, """
      INSERT INTO tickets VALUES
        (1, 1, '2026-06-30 23:59:00', NULL),
        (2, 1, '2026-06-24 00:00:01', '2026-06-25'),
        (3, 1, '2026-06-01 12:00:00', NULL),
        (4, 1, '2026-01-01 08:00:00', NULL),
        (5, 1, '2026-07-02 09:00:00', '2026-07-01'),
        (6, 2, '2026-03-01 09:00:00', NULL),
        (7, 1, '2026-06-23 23:59:59', NULL),
        (10, NULL, '2026-06-01 00:00:00', '2026-06-01')
      """)

      %{base: Selecto.configure(domain(), connection, adapter: Adapter)}
    end

    test "whole calendar days whatever the time, negative when reversed, NULL when missing", %{
      base: base
    } do
      query =
        base
        |> Selecto.select(["id", "lead_days", "refund_days", "lead_bucket", "lead_band"])
        |> Selecto.order_by(X.asc("id"))

      assert rows(query) == [
               [1, 0, nil, "0-6 days", "Week"],
               [2, 6, 1, "0-6 days", "Week"],
               [3, 29, nil, "7-29 days", "Month"],
               [4, 180, nil, "30+ days", nil],
               [5, -2, -1, "After the start", nil],
               [6, nil, nil, "Unknown", nil],
               [7, 7, nil, "7-29 days", "Month"],
               [10, nil, 0, "Unknown", nil]
             ]
    end

    test "group, filter and order on shorthand columns", %{base: base} do
      grouped =
        base
        |> Selecto.select(["lead_bucket", X.as(X.count(), "n")])
        |> Selecto.group_by(["lead_bucket"])
        |> Selecto.order_by(X.asc("lead_bucket"))

      assert rows(grouped) == [
               ["0-6 days", 2],
               ["30+ days", 1],
               ["7-29 days", 2],
               ["After the start", 1],
               ["Unknown", 2]
             ]

      filtered = base |> Selecto.select(["id"]) |> Selecto.filter({"lead_days", {:>=, 7}})
      assert filtered |> Selecto.order_by(X.asc("id")) |> rows() == [[3], [4], [7]]

      labelled = base |> Selecto.select(["id"]) |> Selecto.filter({"lead_bucket", "0-6 days"})
      assert labelled |> Selecto.order_by(X.asc("id")) |> rows() == [[1], [2]]

      {sql, _params} = Selecto.to_sql(Selecto.select(base, ["lead_bucket"]))
      refute sql =~ "days"
      refute sql =~ "Unknown"
    end
  end

  test "days_between reads either stored text form and propagates NULL", %{connection: conn} do
    for {start, finish, expected} <- [
          {"2026-06-30 23:59:00", "2026-06-30", 0},
          {"2026-06-24T00:00:01", "2026-06-30", 6},
          {"2026-07-02", "2026-06-30", -2},
          {"2024-02-28", "2024-03-01", 2},
          {nil, "2026-06-30", nil},
          {"2026-06-30", nil, nil}
        ] do
      fragment = %ComputedValue{
        operation: :days_between,
        expression: [{:param, start}, {:param, finish}],
        type: "integer"
      }

      assert {:ok, sql} = Dialect.render_computed_value(fragment, %{})
      assert scalar(conn, sql) == expected
    end

    assert {:error, _} =
             Dialect.render_computed_value(
               %ComputedValue{
                 operation: :days_between,
                 expression: [{:param, "x"}],
                 type: "integer"
               },
               %{}
             )
  end

  describe "month_ranges" do
    setup %{connection: connection} do
      execute!(connection, "CREATE TABLE loads (id INTEGER PRIMARY KEY, received TEXT)")
      ages = [0, 1, 2, 4, 6, 12, 13]

      ages
      |> Enum.with_index(1)
      |> Enum.each(fn {ago, id} ->
        assert {:ok, _} =
                 Adapter.execute(
                   connection,
                   "INSERT INTO loads VALUES (?, ?)",
                   [id, month_ago(connection, ago)],
                   []
                 )
      end)

      execute!(connection, "INSERT INTO loads VALUES (8, NULL)")
      %{base: Selecto.configure(loads_domain(), connection, adapter: Adapter)}
    end

    test "counts calendar months back from the current month, bounds inclusive", %{base: base} do
      bucket =
        {:bucket, "received",
         %{
           kind: :month_ranges,
           ranges: [
             {6, 12, "half year"},
             {3, 5, "quarter"},
             {2, 2, "two"},
             {1, 1, "last"},
             {0, 0, "this"}
           ]
         }}

      query =
        base |> Selecto.select(["id", X.as(bucket, "band")]) |> Selecto.order_by(X.asc("id"))

      assert Enum.map(rows(query), &List.last/1) ==
               ["this", "last", "two", "quarter", "half year", "half year", "Other", "Other"]
    end

    test "open-ended ranges", %{base: base} do
      bucket =
        {:bucket, "received",
         %{
           kind: :month_ranges,
           ranges: [{13, :infinity, "older"}, {:negative_infinity, 1, "recent"}]
         }}

      query =
        base |> Selecto.select(["id", X.as(bucket, "band")]) |> Selecto.order_by(X.asc("id"))

      assert Enum.map(rows(query), &List.last/1) ==
               ["recent", "recent", "Other", "Other", "Other", "Other", "older", "Other"]
    end

    test "renders through the bucket port", %{connection: conn} do
      assert {:ok, sql} =
               Dialect.render_bucket(
                 %BucketExpression{
                   kind: :month_ranges,
                   expression: {:param, month_ago(conn, 3)},
                   ranges: [{3, 3, "three"}]
                 },
                 %{}
               )

      assert scalar(conn, sql) == "three"
    end
  end

  # The 15th of the month `ago` calendar months before the database's current
  # month, safely inside it.
  defp month_ago(conn, ago) do
    {:ok, %{rows: [[year, month]]}} =
      Adapter.execute(
        conn,
        "SELECT CAST(strftime('%Y', 'now') AS INTEGER), CAST(strftime('%m', 'now') AS INTEGER)",
        [],
        []
      )

    index = year * 12 + (month - 1) - ago

    "#{div(index, 12)}-#{String.pad_leading(Integer.to_string(rem(index, 12) + 1), 2, "0")}-15"
  end

  defp rows(query) do
    assert {:ok, {rows, _, _}} = Selecto.execute(query, analyze_complexity: false)
    rows
  end

  defp scalar(conn, sql) do
    {sql, params} = Selecto.SQL.Params.finalize(["SELECT ", sql], adapter: Adapter)
    assert {:ok, %{rows: [[value]]}} = Adapter.execute(conn, sql, params, [])
    value
  end

  defp execute!(connection, sql), do: assert({:ok, _} = Adapter.execute(connection, sql, [], []))

  defp domain do
    %{
      name: "Tickets",
      source: %{
        source_table: "tickets",
        primary_key: :id,
        fields: [
          :id,
          :event_id,
          :purchased_at,
          :refunded_on,
          :lead_days,
          :refund_days,
          :lead_bucket,
          :lead_band
        ],
        redact_fields: [],
        columns: %{
          id: %{type: :integer},
          event_id: %{type: :integer},
          purchased_at: %{type: :naive_datetime},
          refunded_on: %{type: :date},
          lead_days: %{
            type: :integer,
            computed: %{kind: :temporal_delta, from: "purchased_at", to: "event.starts_on"}
          },
          refund_days: %{
            type: :integer,
            computed: %{kind: :temporal_delta, from: "purchased_at", to: "refunded_on"}
          },
          lead_bucket: %{
            type: :string,
            computed: %{
              kind: :bucket,
              field: "lead_days",
              otherwise: "Unknown",
              buckets: [
                %{label: "After the start", max: -1},
                %{label: "0-6 days", min: 0, max: 6},
                %{label: "7-29 days", min: 7, max: 29},
                %{label: "30+ days", min: 30}
              ]
            }
          },
          lead_band: %{
            type: :string,
            computed: %{
              kind: :bucket,
              field: "lead_days",
              buckets: [%{label: "Week", min: 0, max: 6}, %{label: "Month", min: 7, max: 29}]
            }
          }
        },
        associations: %{
          event: %{queryable: :event, field: :event, owner_key: :event_id, related_key: :id}
        }
      },
      schemas: %{
        event: %{
          source_table: "events",
          primary_key: :id,
          fields: [:id, :name, :starts_on],
          redact_fields: [],
          columns: %{id: %{type: :integer}, name: %{type: :string}, starts_on: %{type: :date}},
          associations: %{}
        }
      },
      joins: %{event: %{type: :left}}
    }
  end

  defp loads_domain do
    %{
      name: "Loads",
      source: %{
        source_table: "loads",
        primary_key: :id,
        fields: [:id, :received],
        redact_fields: [],
        columns: %{id: %{type: :integer}, received: %{type: :date}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }
  end
end
