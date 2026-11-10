defmodule SelectoDBSQLite.ParameterValueTest do
  use ExUnit.Case, async: false

  alias SelectoDBSQLite.Adapter

  setup do
    assert {:ok, connection} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(connection) end)

    for sql <- [
          "CREATE TABLE p (id INTEGER PRIMARY KEY, price NUMERIC)",
          "INSERT INTO p VALUES (1, 1.5), (2, 2.5)"
        ],
        do: {:ok, _} = Adapter.execute(connection, sql, [], [])

    domain = %{
      name: "p",
      source: %{
        source_table: "p",
        primary_key: :id,
        fields: [:id, :price],
        redact_fields: [],
        columns: %{id: %{type: :integer}, price: %{type: :decimal}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    %{query: Selecto.configure(domain, connection, adapter: Adapter, validate: false)}
  end

  test "a NaN or infinite decimal refuses typed instead of comparing as text", %{query: query} do
    # -Infinity would bind as the text '-Infinity', which no number reaches.
    for value <- ["NaN", "Infinity", "-Infinity"], filter <- [{:>=, Decimal.new(value)}] do
      read = query |> Selecto.filter({"price", filter}) |> Selecto.select(["id"])

      for result <- [Selecto.execute(read), Selecto.execute_with_metadata(read)] do
        assert {:error, %Selecto.Error{details: %{reason: :parameter_unbindable}}} = result
      end
    end

    read = query |> Selecto.filter({"price", {:>=, Decimal.new("2.0")}}) |> Selecto.select(["id"])
    assert {:ok, {[[2]], _, _}} = Selecto.execute(read)
  end

  test "an integer field's text value that is not an integer refuses typed", %{query: query} do
    read = query |> Selecto.filter({"id", "abc"}) |> Selecto.select(["id"])

    assert {:error, %Selecto.Error{details: %{reason: :invalid_filter_value}}} =
             Selecto.execute(read)
  end
end
