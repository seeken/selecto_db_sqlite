defmodule SelectoDBSQLite.DialectTest do
  use ExUnit.Case, async: true

  alias Selecto.Dialect.DateTime.Operation, as: DateTimeOperation
  alias Selecto.Dialect.Bucket.Expression, as: BucketExpression
  alias Selecto.Dialect.Predicate.Comparison
  alias SelectoDBSQLite.Dialect

  test "renders date formatting and case-insensitive matching in SQLite syntax" do
    datetime = %DateTimeOperation{
      operation: :format,
      clause: :select,
      expression: ~s("created_at"),
      options: %{format: "YYYY", epoch_storage: nil}
    }

    comparison = %Comparison{
      operation: :case_insensitive_like,
      left: ~s("title"),
      right: {:param, "%office%"}
    }

    assert {:ok, formatted} = Dialect.render_datetime_operation(datetime, %{})
    assert IO.iodata_to_binary(formatted) == ~s|strftime('%Y', "created_at")|
    assert {:ok, compared} = Dialect.render_comparison(comparison, %{})
    assert compared == ["LOWER(", ~s("title"), ") ", "LIKE", " LOWER(", {:param, "%office%"}, ")"]
  end

  test "rejects unimplemented timezone conversion instead of emitting PostgreSQL SQL" do
    datetime = %DateTimeOperation{
      operation: :format,
      clause: :select,
      expression: ~s("created_at"),
      options: %{format: "YYYY", timezone: "America/Denver"}
    }

    assert {:error, %Selecto.Error{details: %{unsupported_feature: :datetime_operation}}} =
             Dialect.render_datetime_operation(datetime, %{})
  end

  test "renders configured datetime group formats" do
    for {format, expected} <- [
          {"YYYY-MM-DD", "%Y-%m-%d"},
          {"YYYY-MM-DD HH24", "%Y-%m-%d %H"},
          {"YYYY-MM", "%Y-%m"},
          {"YYYY-WW", "%Y-%W"},
          {"YYYY-Q", "strftime('%m'"},
          {"D", "%w"}
        ] do
      operation = %DateTimeOperation{
        operation: :format,
        clause: :select,
        expression: "created_at",
        options: %{format: format}
      }

      assert {:ok, rendered} = Dialect.render_datetime_operation(operation, %{})
      assert IO.iodata_to_binary(rendered) =~ expected
    end
  end

  test "renders numeric, relative date, and text prefix buckets" do
    numeric = %BucketExpression{
      kind: :numeric_ranges,
      expression: "price",
      ranges: [{0, 10, "0-10"}, {11, :infinity, "11+"}]
    }

    relative = %BucketExpression{
      kind: :date_relative_ranges,
      expression: "ordered_on",
      ranges: [{"today", "today", "today"}, {1, 7, "1-7"}]
    }

    prefix = %BucketExpression{
      kind: :text_prefix,
      expression: "name",
      prefix_length: 2,
      exclude_articles: ["the", "an", "a"],
      ignore_case: true
    }

    assert {:ok, numeric_sql} = Dialect.render_bucket(numeric, %{})
    assert IO.iodata_to_binary(numeric_sql) =~ "price >= 0 AND price <= 10"

    assert {:ok, relative_sql} = Dialect.render_bucket(relative, %{})
    assert IO.iodata_to_binary(relative_sql) =~ "DATE('now')"

    assert {:ok, prefix_sql} = Dialect.render_bucket(prefix, %{})
    assert IO.iodata_to_binary(prefix_sql) =~ "UPPER(SUBSTR("
    assert IO.iodata_to_binary(prefix_sql) =~ "LIKE 'the %'"
  end
end
