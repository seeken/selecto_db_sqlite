defmodule SelectoDBSQLite.DialectTest do
  use ExUnit.Case, async: true

  alias Selecto.Dialect.DateTime.Operation, as: DateTimeOperation
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
end
