defmodule SelectoDBSQLite.ValueCalendarCollectionTest do
  use ExUnit.Case, async: false
  alias SelectoDBSQLite.{Adapter, Dialect, RuntimeCapabilities}
  alias Selecto.Dialect.ComputedValue
  alias Selecto.Dialect.DateTime.Operation, as: DateTimeOperation
  alias Selecto.Dialect.Collection.Operation, as: CollectionOperation
  alias Selecto.Dialect.Bucket.Expression, as: BucketExpression
  alias Selecto.Dialect.TableFunction.Join
  alias Selecto.Dialect.Text.Normalization

  setup do
    {:ok, conn} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(conn) end)
    %{conn: conn}
  end

  test "computed JSON text uses bound paths and preserves scalar JSON spellings", %{conn: conn} do
    for {doc, path, expected} <- [
          {~s({"a":[true]}), ["a", "0"], "true"},
          {~s({"a":[false]}), ["a", "0"], "false"},
          {~s({"a":[null]}), ["a", "0"], nil},
          {~s({"a":[10]}), ["a", "0"], "10"},
          {~s({"a":["x"]}), ["a", "0"], "x"},
          {~s({"a":{"b":1}}), ["a"], ~s({"b":1})},
          {~s({"a":[]}), ["a", "1"], nil},
          {"not json", ["a"], nil},
          {nil, ["a"], nil}
        ] do
      fragment = %ComputedValue{
        operation: :json_text,
        expression: {:param, doc},
        path: Enum.map(path, &{:param, &1})
      }

      assert {:ok, sql} = Dialect.render_computed_value(fragment, %{})
      assert {_, params} = Selecto.SQL.Params.finalize(sql, adapter: Adapter)
      assert params == [doc | path]
      assert scalar(conn, sql) == expected
    end

    assert {:error, _} =
             Dialect.render_computed_value(
               %ComputedValue{
                 operation: :json_text,
                 expression: "value",
                 path: [{:param, "a' --"}]
               },
               %{}
             )

    assert {:ok, cast} =
             Dialect.render_computed_value(
               %ComputedValue{operation: :cast, expression: {:param, "42"}, type: "integer"},
               %{}
             )

    assert scalar(conn, cast) == 42

    assert {:error, _} =
             Dialect.render_computed_value(
               %ComputedValue{
                 operation: :cast,
                 expression: "value",
                 type: "INTEGER); DROP TABLE t; --"
               },
               %{}
             )
  end

  test "decimal division preserves fractions and parameter order", %{conn: conn} do
    fragment = %ComputedValue{
      operation: :divide,
      expression: [{:param, 5}, {:param, 2}],
      type: "decimal"
    }

    assert {:ok, sql} = Dialect.render_computed_value(fragment, %{})
    assert scalar(conn, sql) == 2.5
    assert {_, [5, 2]} = Selecto.SQL.Params.finalize(sql, adapter: Adapter)
    assert {:error, _} = Dialect.render_computed_value(%{fragment | expression: ["x"]}, %{})
  end

  test "calendar formatting follows ISO year boundaries and numeric Sunday conventions", %{
    conn: conn
  } do
    for {date, format, expected} <- [
          {"2021-01-01", "iso_week", "2020-W53"},
          {"2019-12-30", "iso_week_date", "2020-W01-1"},
          {"2023-01-01", "day_of_week_num", 7},
          {"2023-01-01", "D", 1},
          {"2021-01-01", "YYYY-WW", "2021-01"},
          {"2021-01-08", "YYYY-WW", "2021-02"},
          {"2024-08-17", "quarter", "2024-Q3"},
          {"1970-01-01 00:00:01.234", "epoch_milliseconds", 1234},
          {"bad", "iso_week", nil},
          {nil, "quarter", nil}
        ] do
      assert scalar(conn, datetime(:format, date, options: %{format: format})) == expected
    end

    assert scalar(
             conn,
             datetime(:format, 1_234,
               options: %{
                 format: "rfc3339_millis",
                 epoch_storage: :unix_milliseconds,
                 timezone: "UTC"
               }
             )
           ) == "1970-01-01T00:00:01.234Z"

    assert {:error, _} =
             Dialect.render_datetime_operation(
               %DateTimeOperation{
                 operation: :format,
                 clause: :select,
                 expression: "value",
                 options: %{format: "unknown"}
               },
               %{}
             )
  end

  test "date parts and truncation retain fractions and Monday calendar weeks", %{conn: conn} do
    assert scalar(conn, datetime(:extract_part, "2021-01-01 13:14:05.125", part: :second)) ==
             5.125

    assert scalar(conn, datetime(:extract_part, "2021-01-01", part: :week)) == 53
    assert scalar(conn, datetime(:extract_part, "2024-08-17", part: :quarter)) == 3
    assert scalar(conn, datetime(:extract_part, "1970-01-01 00:00:01.234", part: :epoch)) == 1.234

    assert scalar(conn, datetime(:truncate, "2023-01-01 13:14:05.125", part: :week)) ==
             "2022-12-26 00:00:00"

    assert scalar(conn, datetime(:truncate, "2024-08-17 13:14:05.125", part: :quarter)) ==
             "2024-07-01 00:00:00"

    assert scalar(conn, datetime(:truncate, nil, part: :quarter)) == nil

    for {operation, part} <- [{:age, nil}, {:extract_part, :microseconds}] do
      assert {:error, _} =
               Dialect.render_datetime_operation(
                 %DateTimeOperation{
                   operation: operation,
                   clause: :select,
                   expression: "value",
                   part: part
                 },
                 %{}
               )
    end

    assert scalar(
             conn,
             datetime(:temporal_cutoff, "2999-01-01",
               part: :month,
               options: %{amount: 1, clock: :current_date}
             )
           ) == 1

    assert scalar(
             conn,
             datetime(:temporal_cutoff, "1900-01-01",
               part: :day,
               options: %{amount: 1, clock: :current_timestamp}
             )
           ) == 0
  end

  test "portable numeric buckets handle negative floors and full signed integers", %{conn: conn} do
    for {value, expected} <- [
          {-1, "-10--1"},
          {-10, "-10--1"},
          {-10.5, "-20--11"},
          {0, "0-9"},
          {10, "10-19"},
          {nil, "Other"},
          {9_223_372_036_854_775_000, "9223372036854775000-9223372036854775009"}
        ] do
      assert {:ok, sql} =
               Dialect.render_bucket(
                 %BucketExpression{
                   kind: :numeric_increment,
                   expression: {:param, value},
                   increment: 10
                 },
                 %{}
               )

      assert scalar(conn, sql) == expected
    end

    {:ok, %{rows: [[today]]}} = Adapter.execute(conn, "SELECT date('now')", [], [])

    assert {:ok, sql} =
             Dialect.render_bucket(
               %BucketExpression{
                 kind: :elapsed_days_ranges,
                 expression: {:param, today <> "T23:59:59"},
                 ranges: [{0, 0, "today"}]
               },
               %{}
             )

    assert scalar(conn, sql) == "today"

    assert {:ok, sql} =
             Dialect.render_bucket(
               %BucketExpression{
                 kind: :year_ranges,
                 expression: {:param, 0},
                 temporal_options: %{epoch_storage: :unix_seconds},
                 ranges: [{1970, 1970, "epoch"}]
               },
               %{}
             )

    assert scalar(conn, sql) == "epoch"
  end

  test "article normalization respects configured words and case policy", %{conn: conn} do
    for {text, ignore_case, expected} <- [
          {" The Bear ", true, "bear"},
          {"THE", true, ""},
          {"The Bear", false, "The Bear"},
          {"the bear", false, "bear"},
          {"an apple", true, "an apple"},
          {nil, true, nil}
        ] do
      assert {:ok, sql} =
               Dialect.render_text_normalization(
                 %Normalization{
                   expression: {:param, text},
                   exclude_articles: ["the"],
                   ignore_case: ignore_case
                 },
                 %{}
               )

      assert scalar(conn, sql) == expected
    end

    assert {:ok, sql} =
             Dialect.render_bucket(
               %BucketExpression{
                 kind: :text_prefix,
                 expression: {:param, "THE"},
                 exclude_articles: ["the"],
                 prefix_length: 2
               },
               %{}
             )

    assert scalar(conn, sql) == "Other"
  end

  test "ordered and distinct aggregates preserve JSON and delimiter values", %{conn: conn} do
    {:ok, _} =
      Adapter.execute(conn, "CREATE TABLE values_table(value TEXT, sort INTEGER)", [], [])

    {:ok, _} =
      Adapter.execute(
        conn,
        "INSERT INTO values_table VALUES ('a,b', 2), ('z',1), ('z',1), (NULL,3)",
        [],
        []
      )

    for {operation, opts, expected} <- [
          {:array_agg, [distinct: true, order_by: [{"sort", :asc}]], ~s(["z","a,b",null])},
          {:string_agg, [order_by: [{"sort", :asc}], options: %{delimiter: "|'x"}],
           "z|'xz|'xa,b"},
          {:string_agg, [distinct: true, order_by: [{"sort", :asc}]], "z,a,b"}
        ] do
      op =
        struct!(
          CollectionOperation,
          [operation: operation, clause: :select, column: "value"] ++ opts
        )

      assert {:ok, rendered} = Dialect.render_collection_operation(op, %{})
      sql = if is_tuple(rendered), do: elem(rendered, 0), else: rendered

      {query, params} =
        Selecto.SQL.Params.finalize(["SELECT ", sql, " FROM values_table"], adapter: Adapter)

      assert {:ok, %{rows: [[^expected]]}} = Adapter.execute(conn, query, params, [])
    end

    assert {:error, _} =
             Dialect.render_collection_operation(
               %CollectionOperation{
                 operation: :string_agg,
                 clause: :select,
                 column: "value",
                 distinct: true,
                 options: %{delimiter: "|"}
               },
               %{}
             )
  end

  test "JSON arrays lower constructors, typed containment, lengths and native table joins", %{
    conn: conn
  } do
    assert {:ok, {array_sql, _}} =
             Dialect.render_collection_operation(
               %CollectionOperation{
                 operation: :array,
                 clause: :select,
                 value: [true, nil, 1, "a"]
               },
               %{}
             )

    assert scalar(conn, array_sql) == ~s([true,null,1,"a"])

    assert {:ok, sql} =
             Dialect.render_collection_operation(
               %CollectionOperation{
                 operation: :cardinality,
                 clause: :select,
                 column: {:param, ~s([1,2])}
               },
               %{}
             )

    assert scalar(conn, sql) == 2

    assert {:ok, sql} =
             Dialect.render_collection_operation(
               %CollectionOperation{
                 operation: :array_length,
                 clause: :select,
                 column: {:param, "{}"},
                 dimension: 1
               },
               %{}
             )

    assert scalar(conn, sql) == nil

    for source <- [~s([10,20]), "null", "{}", "bad", nil] do
      {:ok, function} =
        Dialect.render_collection_operation(
          %CollectionOperation{operation: :unnest, clause: :table, column: "t.value"},
          %{}
        )

      {:ok, join} =
        Dialect.render_table_function_join(
          %Join{join_type: :left, source_kind: :table_function, source_sql: function, alias: "j"},
          %{}
        )

      {sql, params} =
        Selecto.SQL.Params.finalize(
          [
            "SELECT j.value, j.key + 1 FROM (SELECT ",
            {:param, source},
            " AS value) AS t ",
            join,
            " ORDER BY j.key"
          ],
          adapter: Adapter
        )

      assert {:ok, %{rows: rows}} = Adapter.execute(conn, sql, params, [])
      assert rows == if(source == "[10,20]", do: [[10, 1], [20, 2]], else: [[nil, nil]])
    end
  end

  test "array predicates distinguish booleans, numbers, nulls and order", %{conn: conn} do
    for {operation, lhs, rhs, expected} <- [
          {:array_contains, [true], [1], 0},
          {:array_contains, [true], [true], 1},
          {:array_overlap, [true], [1], 0},
          {:array_overlap, [1], [1.0], 1},
          {:array_overlap, [nil], [nil], 1},
          {:array_contained, [1, 1, nil], [1.0, nil], 1},
          {:array_contained, [1, true], [1], 0},
          {:array_contained, [], [], 1},
          {:array_overlap, [], [], 0},
          {:array_eq, [1, true], [1.0, true], 1},
          {:array_eq, [1, true], [true, 1], 0},
          {:array_eq, [nil], [], 0}
        ] do
      assert {:ok, sql} =
               Dialect.render_collection_operation(
                 %CollectionOperation{
                   operation: operation,
                   clause: :filter,
                   column: {:param, Jason.encode!(lhs)},
                   value: rhs
                 },
                 %{}
               )

      assert scalar(conn, sql) == expected
    end

    for lhs <- [nil, "not json", "{}", "null"] do
      assert {:ok, sql} =
               Dialect.render_collection_operation(
                 %CollectionOperation{
                   operation: :array_contained,
                   clause: :filter,
                   column: {:param, lhs},
                   value: []
                 },
                 %{}
               )

      assert scalar(conn, sql) == if(is_nil(lhs), do: nil, else: 0)
    end
  end

  test "connected feature probes expose version and compile options and gate safely", %{
    conn: conn
  } do
    info = Adapter.connection_info(conn)
    assert is_binary(info.server_version)
    assert is_list(info.compile_options)
    assert info.features.json
    assert info.features.ordered_aggregate
    assert info.features.window_functions
    assert Adapter.supports?(conn, :json_rowset)
    assert not Adapter.supports?(conn, :symbolic_interval_age)

    for {version, minimum, supported} <- [
          {"3.43.2", {3, 44, 0}, false},
          {"3.44.0", {3, 44, 0}, true},
          {"3.39.0", {3, 39, 0}, true},
          {nil, {3, 44, 0}, false}
        ] do
      assert RuntimeCapabilities.version_at_least?(version, minimum) == supported
    end
  end

  defp datetime(operation, value, opts) do
    assert {:ok, rendered} =
             Dialect.render_datetime_operation(
               struct!(
                 DateTimeOperation,
                 [operation: operation, clause: :select, expression: {:param, value}] ++ opts
               ),
               %{}
             )

    if is_tuple(rendered), do: elem(rendered, 0), else: rendered
  end

  defp scalar(conn, sql) do
    {sql, params} = Selecto.SQL.Params.finalize(["SELECT ", sql], adapter: Adapter)
    assert {:ok, %{rows: [[value]]}} = Adapter.execute(conn, sql, params, [])
    value
  end
end
