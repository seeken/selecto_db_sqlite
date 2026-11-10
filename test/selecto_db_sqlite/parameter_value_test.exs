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

    %{
      connection: connection,
      query: Selecto.configure(domain, connection, adapter: Adapter, validate: false)
    }
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

  test "a server error while a stream is enumerated raises typed; an encode error at open returns typed",
       %{query: query, connection: connection} do
    domain = %{
      name: "j",
      source: %{
        source_table: "j",
        primary_key: :id,
        fields: [:id, :doc],
        redact_fields: [],
        columns: %{id: %{type: :integer}, doc: %{type: :string}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    for sql <- [
          "CREATE TABLE j (id INTEGER PRIMARY KEY, doc TEXT)",
          "INSERT INTO j VALUES (1, '{}'), (2, 'x')"
        ],
        do: {:ok, _} = Adapter.execute(connection, sql, [], [])

    # The second row's malformed JSON fails as its step runs.
    read =
      Selecto.configure(domain, connection, adapter: Adapter, validate: false)
      |> Selecto.filter({:raw_sql_filter, "json_extract(doc, '$.a') IS NULL"})
      |> Selecto.select(["id"])
      |> Selecto.order_by("id")

    assert {:error, %Selecto.Error{} = error} = Selecto.execute(read)
    assert {:ok, stream} = Selecto.execute_stream(read)
    refused = assert_raise Selecto.Error.Refused, fn -> Enum.to_list(stream) end

    assert {refused.type, refused.message, refused.details} ==
             {error.type, error.message, error.details}

    # A parameter the driver cannot bind fails as the stream opens.
    bad = query |> Selecto.filter({"price", {1, 2}}) |> Selecto.select(["id"])
    assert {:error, %Selecto.Error{} = error} = Selecto.execute(bad)
    assert {:error, ^error} = Selecto.execute_stream(bad)
  end
end
