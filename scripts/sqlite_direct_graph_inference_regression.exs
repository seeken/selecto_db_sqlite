defmodule SelectoDBSQLite.DirectGraphInferenceRegression do
  use ExUnit.Case, async: false
  alias SelectoDBSQLite.{Adapter, GraphDomainInference, GraphOwnership}
  alias SelectoUpdato.DirectWrite

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(db) end)
    assert sql(db, "PRAGMA temp_store") == [[2]]
    assert Enum.all?(sql(db, "PRAGMA database_list"), fn [_, _, file] -> file == "" end)

    domain =
      Enum.find(SelectoBackendCertification.EngineDirectWriteCases.all(), &(&1.id == "DW004")).fixture[
        "domain"
      ]

    %{db: db, domain: domain, target: %Selecto{adapter: Adapter, connection: db}}
  end

  for variant <- [:missing_fk, :wrong_fk, :nullable_fk, :nonunique_parent] do
    test "#{variant} cannot infer graph ownership before its root insert", %{
      db: db,
      domain: domain,
      target: target
    } do
      tables(db, unquote(variant))
      before = sql(db, "SELECT total_changes()")

      assert {:error, %{details: %{code: :owned_key_comparison_not_evaluable}}} =
               DirectWrite.execute_graph(domain, target, values("blocked"))

      assert sql(db, "SELECT label FROM selecto_cert_graph_parents") == []
      assert sql(db, "SELECT total_changes()") == before
    end
  end

  test "missing grants and incompatible explicit ownership refuse before DML", %{
    db: db,
    domain: domain,
    target: target
  } do
    tables(db, :ordinary)
    before = sql(db, "SELECT total_changes()")

    for authored <- [
          put_in(domain, ["writes", "relationships", "children", "writable"], false),
          put_in(domain, ["writes", "relationships", "children", "allowed_ops"], ["update"]),
          put_in(
            domain,
            ["writes", "relationships", "children", "ownership"],
            "shared_association"
          )
        ] do
      assert {:error, _} = DirectWrite.execute_graph(authored, target, values("blocked"))
    end

    assert sql(db, "SELECT total_changes()") == before
  end

  test "malformed public map keys return invalid_write without native DML", %{
    db: db,
    domain: domain,
    target: target
  } do
    tables(db, :ordinary)
    before = sql(db, "SELECT total_changes()")
    malformed_domain = put_in(domain, ["source", "columns"], %{{} => %{"type" => "string"}})

    for {authored, payload} <- [
          {domain, %{{} => "invalid"}},
          {domain, %{"label" => "invalid", "children" => [%{{} => "invalid"}]}},
          {malformed_domain, values("invalid")}
        ] do
      assert {:error, %{type: :invalid_write}} =
               DirectWrite.execute_graph(authored, target, payload)
    end

    assert {:error, %{type: :invalid_write}} = DirectWrite.import_domain(malformed_domain)

    ambiguous =
      update_in(domain, ["writes", "operations", "insert"], &Map.put(&1, :enabled, false))

    assert {:error, %{type: :invalid_write}} =
             DirectWrite.execute_graph(ambiguous, target, values("invalid"))

    assert {:error, %{type: :invalid_write}} =
             DirectWrite.execute_graph(
               domain,
               target,
               Map.put(values("invalid"), :label, "contradiction")
             )

    for query <- [target, %{filters: []}] do
      assert {:error, %{type: :invalid_write}} =
               DirectWrite.execute_graph(domain, target, values("invalid"), query: query)
    end

    assert sql(db, "SELECT total_changes()") == before
    assert sql(db, "SELECT label FROM selecto_cert_graph_parents") == []
  end

  test "native child uniqueness establishes one cardinality and refuses two children", %{
    db: db,
    domain: domain,
    target: target
  } do
    tables(db, :unique_child)
    assert {:ok, _} = DirectWrite.execute_graph(domain, target, values("one"))

    assert sql(
             db,
             "SELECT p.label,c.note,t.tag FROM selecto_cert_graph_parents p JOIN selecto_cert_graph_children c ON p.id=c.parent_id JOIN selecto_cert_graph_tags t ON c.id=t.child_id"
           ) == [["one", "child", "tag"]]

    payload = %{"label" => "two", "children" => [%{"note" => "a"}, %{"note" => "b"}]}
    before = sql(db, "SELECT total_changes()")
    assert {:error, _} = DirectWrite.execute_graph(domain, target, payload)
    assert sql(db, "SELECT total_changes()") == before
  end

  test "graph candidate Rules require actual native storage and ignore caller providers", %{
    db: db,
    domain: domain,
    target: target
  } do
    tables(db, :incompatible_label)
    governed = candidate_rule(domain)
    before = sql(db, "SELECT total_changes()")

    forged = fn _ ->
      {:ok,
       %Selecto.Write.RecordState{
         values: %{"label" => "kept"},
         complete?: true,
         protection: :locked
       }}
    end

    assert {:error, %{details: %{code: :required_data_rule_pending}}} =
             DirectWrite.execute_graph(governed, target, values("kept"),
               rule_candidate_provider: forged,
               native_rule_candidate?: false
             )

    assert sql(db, "SELECT total_changes()") == before
    assert sql(db, "SELECT label FROM selecto_cert_graph_parents") == []

    for table <-
          ~w(selecto_cert_graph_tags selecto_cert_graph_children selecto_cert_graph_parents),
        do: sql(db, "DROP TABLE #{table}")

    tables(db, :ordinary)
    assert {:ok, _} = DirectWrite.execute_graph(governed, target, values("kept"))
    assert sql(db, "SELECT label FROM selecto_cert_graph_parents") == [["kept"]]
    before = sql(db, "SELECT total_changes()")

    assert {:error, %{details: %{code: :data_rule_failed}}} =
             DirectWrite.execute_graph(governed, target, values("blocked"))

    # Only the native TEMP projection is inserted; no business node is written.
    [[prior_changes]] = before
    assert sql(db, "SELECT total_changes()") == [[prior_changes + 1]]
    assert sql(db, "SELECT label FROM selecto_cert_graph_parents") == [["kept"]]
    assert sql(db, "SELECT name FROM temp.sqlite_schema") == []
  end

  test "a real late constraint failure rolls back root and intermediate writes", %{
    db: db,
    domain: domain,
    target: target
  } do
    tables(db, :ordinary)
    assert {:ok, _} = DirectWrite.execute_graph(domain, target, values("kept"))
    before = sql(db, "SELECT total_changes()")
    bad = put_in(values("rollback"), ["children", Access.at(0), "tags", Access.at(0), "tag"], nil)

    assert {:error,
            %{
              type: :native_constraint_violation,
              details: %{category: :not_null_violation, column: "selecto_cert_graph_tags.tag"}
            }} = DirectWrite.execute_graph(domain, target, bad)

    # total_changes counts rolled-back inserts too, proving failure happened
    # after the real root and intermediate DML rather than during preflight.
    assert sql(db, "SELECT total_changes()") > before
    assert sql(db, "SELECT label FROM selecto_cert_graph_parents") == [["kept"]]
    assert sql(db, "SELECT note FROM selecto_cert_graph_children") == [["child"]]
    assert sql(db, "SELECT tag FROM selecto_cert_graph_tags") == [["tag"]]
    assert {:ok, _} = DirectWrite.execute_graph(domain, target, values("after"))
    assert length(sql(db, "SELECT id FROM selecto_cert_graph_parents")) == 2
  end

  test "physical FK loss after inference cannot retain a graph admission proof", %{
    db: db,
    domain: domain
  } do
    tables(db, :ordinary)
    domain = native_domain(domain)
    assert {:ok, %{domain: inferred, edges: edges}} = GraphDomainInference.infer(db, domain, [])
    operation = inferred |> SelectoUpdato.new() |> SelectoUpdato.insert(values("not-written"))
    assert {:ok, graph, _} = SelectoUpdato.PortableCommand.compile(operation)
    graph = %{graph | metadata: Map.put(graph.metadata, :catalog_inferred_edges, edges)}
    sql(db, "DROP TABLE selecto_cert_graph_tags")

    sql(
      db,
      "CREATE TABLE selecto_cert_graph_tags(id INTEGER PRIMARY KEY,child_id INTEGER NOT NULL,tag TEXT NOT NULL)"
    )

    assert {:error, _} = GraphOwnership.validate(db, graph, [])
    assert sql(db, "SELECT label FROM selecto_cert_graph_parents") == []
  end

  test "authoritative main proof cannot borrow an attached memory schema", %{
    db: db,
    domain: domain
  } do
    tables(db, :missing_fk)
    sql(db, "ATTACH DATABASE ':memory:' AS other")

    sql(
      db,
      "CREATE TABLE other.selecto_cert_graph_parents(id INTEGER PRIMARY KEY,label TEXT NOT NULL)"
    )

    sql(
      db,
      "CREATE TABLE other.selecto_cert_graph_children(id INTEGER PRIMARY KEY,parent_id INTEGER NOT NULL REFERENCES selecto_cert_graph_parents(id),note TEXT NOT NULL)"
    )

    sql(
      db,
      "CREATE TABLE other.selecto_cert_graph_tags(id INTEGER PRIMARY KEY,child_id INTEGER NOT NULL REFERENCES selecto_cert_graph_children(id),tag TEXT NOT NULL)"
    )

    assert {:error, _} = GraphDomainInference.infer(db, native_domain(domain), schema: "other")

    for table <-
          ~w(selecto_cert_graph_tags selecto_cert_graph_children selecto_cert_graph_parents),
        do: sql(db, "DROP TABLE main.#{table}")

    tables(db, :ordinary)
    sql(db, "DROP TABLE other.selecto_cert_graph_tags")
    sql(db, "DROP TABLE other.selecto_cert_graph_children")

    sql(
      db,
      "CREATE TABLE other.selecto_cert_graph_children(id INTEGER PRIMARY KEY,parent_id INTEGER,note TEXT)"
    )

    sql(
      db,
      "CREATE TABLE other.selecto_cert_graph_tags(id INTEGER PRIMARY KEY,child_id INTEGER,tag TEXT)"
    )

    assert {:ok, _} = GraphDomainInference.infer(db, native_domain(domain), schema: "other")
    assert Enum.all?(sql(db, "PRAGMA database_list"), fn [_, _, file] -> file == "" end)
    assert sql(db, "SELECT label FROM main.selecto_cert_graph_parents") == []
  end

  test "host tenant context narrows source tenant inference without a captured query", %{
    db: db,
    target: target
  } do
    fixture =
      Enum.find(SelectoBackendCertification.EngineDirectWriteCases.all(), &(&1.id == "DW002")).fixture

    sql(
      db,
      "CREATE TABLE selecto_cert_api_writes(id INTEGER PRIMARY KEY,tenant_id INTEGER,name TEXT,secret TEXT)"
    )

    sql(db, "INSERT INTO selecto_cert_api_writes VALUES(1,7,'a',NULL),(3,8,'c',NULL)")

    command = %{
      "operation" => "update",
      "relation" => "root",
      "assignments" => %{"name" => "cross"},
      "predicate" => %{"field" => "id", "op" => "eq", "value" => 3},
      "returning" => []
    }

    assert {:error, %{type: :cardinality_mismatch}} =
             DirectWrite.execute(fixture.domain, target, command, tenant: %{"tenant_id" => 7})

    assert sql(db, "SELECT id,name FROM selecto_cert_api_writes ORDER BY id") == [
             [1, "a"],
             [3, "c"]
           ]

    assert {:error, %{type: :invalid_write}} =
             DirectWrite.build(fixture.domain, Map.put(command, "scope", %{"tenant_id" => 8}))

    optional =
      put_in(fixture.domain, ["writes", "scope"], %{
        "tenant" => %{"field" => "tenant_id", "required" => true, "satisfied_by" => ["filter"]}
      })

    {:ok, imported} = DirectWrite.import_domain(optional)
    runtime = Selecto.Runtime.Context.new(Adapter, db)

    query =
      imported
      |> Selecto.configure(runtime, adapter: Adapter, validate: false)
      |> Selecto.filter({"tenant_id", 7})

    assert {:error, %{type: :missing_tenant_scope}} =
             DirectWrite.execute(optional, target, command, query: query)

    for scope <- [%{}, nil, %{"tenant" => nil}] do
      authored = put_in(fixture.domain, ["writes", "scope"], scope)

      assert {:error, %{type: type}} =
               DirectWrite.execute(authored, target, command, query: query)

      assert type in [:missing_tenant_scope, :invalid_domain]
    end

    assert {:error, %{type: :invalid_write}} =
             DirectWrite.build(fixture.domain, command, query: %{filters: [{"tenant_id", 8}]})

    assert sql(db, "SELECT id,name FROM selecto_cert_api_writes ORDER BY id") == [
             [1, "a"],
             [3, "c"]
           ]
  end

  defp values(label),
    do: %{"label" => label, "children" => [%{"note" => "child", "tags" => [%{"tag" => "tag"}]}]}

  defp tables(db, variant) do
    parent_key = if variant == :nonunique_parent, do: "INTEGER", else: "INTEGER PRIMARY KEY"

    foreign =
      case variant do
        :missing_fk -> ""
        :wrong_fk -> " REFERENCES selecto_cert_graph_tags(id)"
        _ -> " REFERENCES selecto_cert_graph_parents(id)"
      end

    notnull = if variant == :nullable_fk, do: "", else: " NOT NULL"
    unique = if variant == :unique_child, do: " UNIQUE", else: ""
    label_type = if variant == :incompatible_label, do: "INTEGER", else: "TEXT"

    sql(
      db,
      "CREATE TABLE selecto_cert_graph_parents(id #{parent_key},label #{label_type} NOT NULL)"
    )

    sql(
      db,
      "CREATE TABLE selecto_cert_graph_children(id INTEGER PRIMARY KEY,parent_id INTEGER#{notnull}#{unique}#{foreign},note TEXT NOT NULL)"
    )

    sql(
      db,
      "CREATE TABLE selecto_cert_graph_tags(id INTEGER PRIMARY KEY,child_id INTEGER NOT NULL REFERENCES selecto_cert_graph_children(id),tag TEXT NOT NULL)"
    )
  end

  defp native_domain(domain) do
    # Production import refuses incomplete relationship metadata. The adapter
    # inference request accepts the vocabulary without inventing such policy.
    ["writes", "relationships", "children", "domain", "writes", "relationships", "tags"]
    |> then(fn path ->
      domain = put_in(domain, ["writes", "relationships", "children", "cardinality"], "many")
      domain = put_in(domain, ["writes", "relationships", "children", "ownership"], "composition")
      domain = put_in(domain, path ++ ["cardinality"], "many")
      domain = put_in(domain, path ++ ["ownership"], "composition")
      {:ok, imported} = DirectWrite.import_domain(domain)
      imported
    end)
  end

  defp candidate_rule(domain) do
    Map.put(domain, "rules", %{
      "schema" => "selecto.data_rules.v1",
      "definitions" => %{
        "kept" => %{"version" => 1, "test" => %{"op" => "value.eq", "value" => "kept"}}
      },
      "normalizers" => %{},
      "bindings" => %{
        "kept" => %{
          "subject" => %{"scope" => "candidate", "path" => ["label"]},
          "operations" => ["insert"],
          "rule" => %{"id" => "kept", "version" => 1}
        }
      }
    })
  end

  defp sql(db, text) do
    {:ok, result} = Adapter.execute(db, text, [], [])
    result.rows
  end
end
