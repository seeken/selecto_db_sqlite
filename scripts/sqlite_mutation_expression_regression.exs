defmodule SelectoDBSQLite.MutationExpressionRegression do
  use ExUnit.Case, async: false
  alias SelectoDBSQLite.Adapter
  alias SelectoUpdato.{DirectWrite, Mutation, PortableCommand}

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(db) end)
    assert sql(db, "PRAGMA temp_store") == [[2]]
    assert Enum.all?(sql(db, "PRAGMA database_list"), fn [_, _, file] -> file == "" end)

    sql(
      db,
      "CREATE TABLE selecto_cert_api_writes(id INTEGER PRIMARY KEY,tenant_id INTEGER,name TEXT,secret TEXT)"
    )

    sql(
      db,
      "INSERT INTO selecto_cert_api_writes VALUES(1,7,'a','hidden'),(2,7,'b','hidden'),(3,8,'c','hidden')"
    )

    %{db: db, target: %Selecto{adapter: Adapter, connection: db}, domain: domain()}
  end

  test "all seven frozen DW005 probes observe actual native rows through the public bridge", %{
    db: db,
    target: target
  } do
    fixture =
      Enum.find(SelectoBackendCertification.EngineDirectWriteCases.all(), &(&1.id == "DW005"))

    {:equal, expected} = fixture.expect

    observations =
      Enum.map(fixture.fixture.probes, fn probe ->
        [command] = probe["commands"]
        result = DirectWrite.execute(fixture.fixture.domain, target, command)
        observed = %{id: probe["id"], accepted: match?({:ok, _}, result), rows: rows(db)}

        case result do
          {:ok, _} ->
            observed

          {:error, error} ->
            Map.put(observed, :error, to_string(Map.get(error.details, :code, error.type)))
        end
      end)

    IO.inspect(observations, label: "DW005 actual observations", limit: :infinity)
    assert observations == expected
  end

  for id <- ["DW001", "DW002"] do
    test "exact #{id} direct-write probes preserve governed native state", %{
      db: db,
      target: target
    } do
      fixture =
        Enum.find(
          SelectoBackendCertification.EngineDirectWriteCases.all(),
          &(&1.id == unquote(id))
        )

      {:equal, expected} = fixture.expect

      observations =
        Enum.map(fixture.fixture.probes, fn probe ->
          result =
            case probe["action"] do
              "execute" ->
                DirectWrite.execute(fixture.fixture.domain, target, hd(probe["commands"]))

              "batch" ->
                DirectWrite.execute_batch(fixture.fixture.domain, target, probe["commands"])
            end

          observed = %{id: probe["id"], accepted: match?({:ok, _}, result), rows: rows(db)}

          case result do
            {:ok, _} ->
              observed

            {:error, error} ->
              Map.put(observed, :error, to_string(Map.get(error.details, :code, error.type)))
          end
        end)

      IO.inspect(observations, label: unquote(id) <> " actual observations", limit: :infinity)
      assert observations == expected
    end
  end

  test "typed NULL retains its declared SQL type and required null inserts refuse", %{
    db: db,
    target: target,
    domain: domain
  } do
    operation =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({"id", 1})
      |> SelectoUpdato.update(%{"name" => Mutation.null(:string)})

    assert {:ok, command, _} = PortableCommand.compile(operation)
    assert [%{value: {:mutation, {:literal, nil, :string}}}] = command.assignments
    assert {:ok, statement} = SelectoDBSQLite.WriteCompiler.compile(command, [])
    assert statement.text =~ "CAST(? AS TEXT)"
    assert {:ok, _} = SelectoUpdato.execute(operation, target)
    assert hd(rows(db)) == [1, 7, nil]
    required = put_in(domain, ["writes", "fields", "name", "required"], true)

    insert =
      required
      |> SelectoUpdato.new()
      |> SelectoUpdato.insert(%{"id" => 4, "tenant_id" => 7, "name" => Mutation.null(:string)})

    assert {:error, %{details: %{code: :missing_required_write_fields}}} =
             SelectoUpdato.execute(insert, target)

    assert length(rows(db)) == 3
  end

  test "simultaneous assignments read original values and bind hostile literals", %{
    db: db,
    target: target,
    domain: domain
  } do
    operation =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({"id", 1})
      |> SelectoUpdato.update(%{
        "tenant_id" => Mutation.increment("tenant_id", 2),
        "name" => Mutation.coalesce([nil, "fallback' OR 1=1 --"])
      })

    assert {:ok, _} = SelectoUpdato.execute(operation, target)
    assert rows(db) == [[1, 9, "fallback' OR 1=1 --"], [2, 7, "b"], [3, 8, "c"]]
    assert {:ok, command, _} = PortableCommand.compile(operation)
    assert :mutation_expressions in command.required_capabilities
    assert {:ok, statement} = SelectoDBSQLite.WriteCompiler.compile(command, [])
    refute statement.text =~ "fallback'"
    assert "fallback' OR 1=1 --" in statement.params

    simultaneous =
      domain
      |> put_in(["writes", "fields", "id", "updatable"], true)
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({"id", 3})
      |> SelectoUpdato.update(%{
        "id" => Mutation.increment("id", 10),
        "tenant_id" => Mutation.add(Mutation.field("id"), Mutation.field("tenant_id"))
      })

    assert {:ok, _} = SelectoUpdato.execute(simultaneous, target)
    assert rows(db) == [[1, 9, "fallback' OR 1=1 --"], [2, 7, "b"], [13, 11, "c"]]
  end

  test "source ownership, operand types, SQL escapes, and bounded trees fail before dispatch", %{
    db: db,
    target: target,
    domain: domain
  } do
    before = sql(db, "SELECT total_changes()")

    deep =
      Enum.reduce(1..34, Mutation.field("tenant_id"), fn _, node -> Mutation.add(node, 1) end)

    for expression <- [
          Mutation.field("foreign.tenant_id"),
          Mutation.add(Mutation.field("name"), 1),
          Mutation.coalesce(["x"]),
          Mutation.coalesce(List.duplicate("x", 17)),
          deep,
          %{"$mutation" => "raw_sql", "args" => ["SELECT 1"]},
          %{"$mutation" => "add", "args" => [%{"$mutation" => "default"}, 1]}
        ] do
      operation =
        domain
        |> SelectoUpdato.new()
        |> SelectoUpdato.filter({"id", 1})
        |> SelectoUpdato.update(%{"tenant_id" => expression})

      assert {:error, _} = SelectoUpdato.execute(operation, target)
    end

    assert rows(db) == [[1, 7, "a"], [2, 7, "b"], [3, 8, "c"]]
    assert sql(db, "SELECT total_changes()") == before
  end

  test "candidate Rules evaluate native arithmetic and preserve the original expression", %{
    db: db,
    target: target,
    domain: domain
  } do
    domain = rules(domain, "number.gt", "0")

    good =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({"id", 1})
      |> SelectoUpdato.update(%{"tenant_id" => Mutation.subtract(Mutation.field("tenant_id"), 2)})

    assert {:ok, _} = SelectoUpdato.execute(good, target)
    assert hd(rows(db)) == [1, 5, "a"]
    bad = %{good | changes: %{"tenant_id" => Mutation.subtract(Mutation.field("tenant_id"), 10)}}
    assert {:error, %{details: %{code: :data_rule_failed}}} = SelectoUpdato.execute(bad, target)
    assert hd(rows(db)) == [1, 5, "a"]
    assert sql(db, "SELECT name FROM temp.sqlite_master") == []
  end

  test "native integer division is used for candidate Rules and DML", %{
    db: db,
    target: target,
    domain: domain
  } do
    domain = rules(domain, "value.eq", 3)

    operation =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({"id", 1})
      |> SelectoUpdato.update(%{"tenant_id" => Mutation.divide(Mutation.field("tenant_id"), 2)})

    assert {:ok, _} = SelectoUpdato.execute(operation, target)
    assert hd(rows(db)) == [1, 3, "a"]
  end

  test "atomic multi rejects invalid expression before its valid prefix writes", %{
    db: db,
    target: target,
    domain: domain
  } do
    good =
      domain
      |> SelectoUpdato.new()
      |> SelectoUpdato.filter({"id", 1})
      |> SelectoUpdato.update(%{"tenant_id" => Mutation.increment("tenant_id")})

    bad = %{good | changes: %{"tenant_id" => Mutation.field("ghost")}}
    multi = %SelectoUpdato.Multi{operations: [first: good, bad: bad]}
    before = sql(db, "SELECT total_changes()")
    assert {:error, _} = SelectoUpdato.run(multi, target)
    assert rows(db) == [[1, 7, "a"], [2, 7, "b"], [3, 8, "c"]]
    assert sql(db, "SELECT total_changes()") == before
  end

  defp domain do
    fixture =
      Enum.find(SelectoBackendCertification.EngineDirectWriteCases.all(), &(&1.id == "DW005"))

    Map.put(fixture.fixture.domain, "schemas", %{})
  end

  defp rules(domain, op, bound) do
    test =
      if op == "value.eq",
        do: %{"op" => op, "value" => bound},
        else: %{"op" => op, "bound" => bound}

    Map.put(domain, "rules", %{
      "schema" => "selecto.data_rules.v1",
      "definitions" => %{"positive" => %{"version" => 1, "test" => test}},
      "normalizers" => %{},
      "bindings" => %{
        "positive" => %{
          "subject" => %{"scope" => "candidate", "path" => ["tenant_id"]},
          "operations" => ["update"],
          "rule" => %{"id" => "positive", "version" => 1}
        }
      }
    })
  end

  defp rows(db), do: sql(db, "SELECT id,tenant_id,name FROM selecto_cert_api_writes ORDER BY id")

  defp sql(db, text) do
    {:ok, result} = Adapter.execute(db, text, [], [])
    result.rows
  end
end
