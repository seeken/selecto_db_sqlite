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

  test "a Decimal no double holds, a year past 9999 and a float special refuse typed",
       %{query: query} do
    long = %Decimal{sign: 1, coef: 14_999_999_999_999_999_999_999_999_999_999_999_999, exp: -37}

    for filter <- [
          {"price", {:>=, long}},
          {"price", {:>=, Decimal.new("1e-400")}},
          {"price", {:in, [Decimal.new("-1e400")]}},
          {"price", {:>=, :inf}}
        ] do
      read = query |> Selecto.filter(filter) |> Selecto.select(["id"])

      assert {:error, %Selecto.Error{details: %{reason: :parameter_unbindable}}} =
               Selecto.execute(read),
             inspect(filter)
    end

    # 1.4999...(37 digits) is no 1.50.
    read =
      query |> Selecto.filter({"price", {:>=, Decimal.new("1.49")}}) |> Selecto.select(["id"])

    assert {:ok, {rows, _, _}} = Selecto.execute(read)
    assert Enum.sort(rows) == [[1], [2]]
  end

  test "a write of a value SQLite cannot bind faithfully refuses before it runs",
       %{connection: connection} do
    {:ok, _} =
      Adapter.execute(connection, "CREATE TABLE w (id INTEGER, price NUMERIC, d TEXT)", [], [])

    for {field, value} <- [
          {:price, Decimal.new("NaN")},
          {:price, Decimal.new("Infinity")},
          {:price, Decimal.new("-1e400")},
          {:d, Date.new!(10_000, 1, 1)}
        ] do
      {:ok, insert} =
        Selecto.Write.Command.new(%{
          operation: :insert,
          relation: :w,
          assignments: [
            %{field: :id, value: {:literal, 1}},
            %{field: field, value: {:literal, value}}
          ]
        })

      assert {:error, %Selecto.Write.Error{type: :invalid_value, details: details}} =
               Adapter.execute_write_unsafe(connection, insert, []),
             inspect(value)

      assert details.reason == :parameter_unbindable
    end

    assert {:ok, %{rows: [[0]]}} = Adapter.execute(connection, "SELECT COUNT(*) FROM w", [], [])
  end

  test "a stored infinite REAL reads as a typed error and the connection stays usable",
       %{connection: connection} do
    {:ok, _} = Adapter.execute(connection, "CREATE TABLE f (id INTEGER, x REAL)", [], [])
    {:ok, _} = Adapter.execute(connection, "INSERT INTO f VALUES (1, 9e999), (2, 1.5)", [], [])

    domain = %{
      name: "f",
      source: %{
        source_table: "f",
        primary_key: :id,
        fields: [:id, :x],
        redact_fields: [],
        columns: %{id: %{type: :integer}, x: %{type: :float}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    read =
      Selecto.configure(domain, connection, adapter: Adapter, validate: false)
      |> Selecto.select(["id", "x"])

    assert {:error, %Selecto.Error{type: :query_error}} = Selecto.execute(read)

    assert {:ok, stream} = Selecto.execute_stream(read)
    assert_raise Selecto.Error.Refused, fn -> Enum.to_list(stream) end

    finite = Selecto.filter(read, {"id", 2})
    assert {:ok, {[[2, 1.5]], _, _}} = Selecto.execute(finite)
    assert {:ok, %{rows: [[1]]}} = Adapter.execute_query(connection, "SELECT 1", [], [])
  end

  test "a UUID in another text form compares as its canonical text", %{connection: connection} do
    {:ok, _} = Adapter.execute(connection, "CREATE TABLE u (id INTEGER, u TEXT)", [], [])

    {:ok, _} =
      Adapter.execute(
        connection,
        "INSERT INTO u VALUES (1, '2b2b2b2b-2b2b-4b2b-8b2b-2b2b2b2b2b2b'), (2, '33333333-3333-4333-8333-333333333333')",
        [],
        []
      )

    domain = %{
      name: "u",
      source: %{
        source_table: "u",
        primary_key: :id,
        fields: [:id, :u],
        redact_fields: [],
        columns: %{id: %{type: :integer}, u: %{type: :uuid}},
        associations: %{}
      },
      schemas: %{},
      joins: %{}
    }

    read = fn value ->
      Selecto.configure(domain, connection, adapter: Adapter, validate: false)
      |> Selecto.filter({"u", value})
      |> Selecto.select(["id"])
    end

    for value <- [
          "2b2b2b2b-2b2b-4b2b-8b2b-2b2b2b2b2b2b",
          "2B2B2B2B-2B2B-4B2B-8B2B-2B2B2B2B2B2B",
          "2b2b2b2b2b2b4b2b8b2b2b2b2b2b2b2b"
        ] do
      assert {:ok, {[[1]], _, _}} = Selecto.execute(read.(value)), value
    end

    assert {:error, %Selecto.Error{details: %{reason: :invalid_filter_value}}} =
             Selecto.execute(read.("not-a-uuid"))
  end
end
