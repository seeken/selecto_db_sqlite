defmodule SelectoDBSQLite.GraphOwnershipTest do
  use ExUnit.Case, async: true

  alias Selecto.Write.{CandidateRequest, CandidateState, Command, Error, Graph, RecordRequest}
  alias Selecto.Write.Graph.{Binding, Node, Row}
  alias SelectoDBSQLite.{Adapter, GraphOwnership, InsertAdmission}

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory, foreign_keys: true)
    on_exit(fn -> Adapter.disconnect(db) end)
    %{db: db}
  end

  test "both protected snapshot ports refuse before exposing a collation-aliased child", %{db: db} do
    tables(db, "TEXT COLLATE BINARY", "TEXT COLLATE NOCASE", "A", "a", "A")
    changes = sql(db, "SELECT total_changes()")

    assert {:error, %Error{details: %{code: :owned_key_comparison_not_evaluable}}} =
             Adapter.load_candidate_state(db, collection_request("a"))

    assert {:error, %Error{details: %{code: :owned_key_comparison_not_evaluable}}} =
             Adapter.load_record_state(db, record_request("a"))

    assert sql(db, "SELECT total_changes()") == changes
    assert sql(db, "SELECT reference FROM children") == [["original"]]
  end

  test "native affinity is part of protected ownership, not the domain field type", %{db: db} do
    tables(db, "TEXT", "NUMERIC", "1", "01", 1)

    assert {:error, %Error{details: %{code: :owned_key_comparison_not_evaluable}}} =
             Adapter.load_candidate_state(db, collection_request("01"))

    assert {:error, %Error{details: %{code: :owned_key_comparison_not_evaluable}}} =
             Adapter.load_record_state(db, record_request("01"))
  end

  test "matching TEXT affinity aliases retain exact owned snapshots", %{db: db} do
    tables(db, "TEXT COLLATE BINARY", "VARCHAR COLLATE BINARY", "A", "a", "A")

    assert {:ok, %CandidateState{rows: [], complete?: true}} =
             Adapter.load_candidate_state(db, collection_request("a"))

    assert {:ok, %CandidateState{rows: [%{"id" => 1, "reference" => "original"}]}} =
             Adapter.load_candidate_state(db, collection_request("A"))

    assert {:error, %Error{type: :cardinality_mismatch, details: %{actual: 0}}} =
             Adapter.load_record_state(db, record_request("a"))
  end

  test "bound edges and empty sync ownership guards are admitted before root DML", %{db: db} do
    tables(db, "TEXT COLLATE BINARY", "TEXT COLLATE NOCASE", "A", "a", "A")

    for kind <- [:binding, :empty_sync] do
      graph = graph(kind, "a")
      changes = sql(db, "SELECT total_changes()")

      assert {:error, %Error{details: %{code: :owned_key_comparison_not_evaluable}}} =
               Adapter.execute_write_unsafe(db, graph)

      assert sql(db, "SELECT total_changes()") == changes

      assert sql(db, "SELECT id,reference FROM parents ORDER BY id") == [
               ["A", "left"],
               ["a", "right"]
             ]

      assert sql(db, "SELECT owner_id,reference FROM children") == [["A", "original"]]
    end
  end

  for shadow <- [
        "CREATE TEMP TABLE CHILDREN(id INTEGER,owner_id TEXT,reference TEXT)",
        "CREATE TEMP VIEW CHILDREN AS SELECT * FROM main.children"
      ] do
    test "physical generated graph catalog refuses uppercase TEMP shadow: #{shadow}", %{db: db} do
      tables(db, "TEXT", "TEXT", "A", "a", "A")
      sql(db, unquote(shadow))

      assert {:error, %Error{details: %{code: :owned_key_comparison_not_evaluable}}} =
               GraphOwnership.validate(db, graph(:empty_sync, "A"), [])
    end
  end

  test "physical generated graph catalog refuses trigger transforms", %{db: db} do
    tables(db, "TEXT", "TEXT", "A", "a", "A")
    sql(db, "CREATE TRIGGER transform AFTER UPDATE ON CHILDREN BEGIN SELECT 1; END")

    assert {:error, %Error{details: %{code: :owned_key_comparison_not_evaluable}}} =
             GraphOwnership.validate(db, graph(:binding, "A"), [])
  end

  test "catalog keeps Unicode case pairs and dollar identifiers physically distinct", %{db: db} do
    sql(db, """
    CREATE TABLE names(id TEXT COLLATE BINARY PRIMARY KEY,
      owner_Ä TEXT COLLATE NOCASE, owner_ä TEXT COLLATE BINARY,
      owner$key TEXT COLLATE RTRIM, "quoted space" TEXT COLLATE NOCASE,
      "prımary" "ınt")
    """)

    assert {:ok, schema} = InsertAdmission.storage_schema(db, "names", [])
    assert schema["owner_Ä"].collation == "NOCASE"
    assert schema["owner_ä"].collation == "BINARY"
    assert schema["owner$key"].collation == "RTRIM"
    assert schema["quoted space"].collation == "NOCASE"
    assert schema["prımary"].declared_type == "ıNT"

    assert :ok = GraphOwnership.require_comparison(schema, :id, schema, "owner_ä")
    assert {:error, %Error{}} = GraphOwnership.require_comparison(schema, :id, schema, "owner_Ä")
  end

  for declaration <- [
        "id TEXT COLLATE NOCASE",
        "id TEXT COLLATE NOCASE, reference TEXT, PRIMARY KEY(id COLLATE BINARY)",
        "id TEXT COLLATE NOCASE, reference TEXT, UNIQUE(id COLLATE BINARY)",
        "id TEXT COLLATE NOCASE, reference TEXT, PRIMARY KEY(id,reference)"
      ] do
    test "graph and both snapshot ports refuse an unproved unique parent: #{declaration}", %{
      db: db
    } do
      declaration = unquote(declaration)

      suffix =
        if String.contains?(declaration, "reference TEXT"), do: "", else: ", reference TEXT"

      sql(db, "CREATE TABLE parents(#{declaration}#{suffix})")

      sql(
        db,
        "CREATE TABLE children(id INTEGER PRIMARY KEY,owner_id TEXT COLLATE NOCASE,reference TEXT)"
      )

      sql(db, "INSERT INTO parents(id,reference) VALUES('A','left'),('B','right')")
      sql(db, "INSERT INTO children VALUES(1,'A','original')")
      refuse_all_ports(db)
    end
  end

  for foreign <- [
        "FOREIGN KEY(owner_id) REFERENCES other_parents(id)",
        "FOREIGN KEY(owner_id) REFERENCES parents(id), FOREIGN KEY(owner_id) REFERENCES other_parents(id)",
        "FOREIGN KEY(owner_id,reference) REFERENCES other_parents(id,reference)"
      ] do
    test "all relevant FK groups must agree with declared ownership: #{foreign}", %{db: db} do
      sql(db, "CREATE TABLE parents(id TEXT PRIMARY KEY,reference TEXT)")

      sql(
        db,
        "CREATE TABLE other_parents(id TEXT,reference TEXT,PRIMARY KEY(id,reference),UNIQUE(id))"
      )

      sql(
        db,
        "CREATE TABLE children(id INTEGER PRIMARY KEY,owner_id TEXT,reference TEXT,#{unquote(foreign)})"
      )

      sql(db, "INSERT INTO parents VALUES('A','left'),('B','right')")
      sql(db, "INSERT INTO other_parents VALUES('A','original')")
      sql(db, "INSERT INTO children VALUES(1,'A','original')")
      refuse_all_ports(db)
    end
  end

  for reference <- [
        "",
        ", FOREIGN KEY(owner_id) REFERENCES parents",
        ", FOREIGN KEY(owner_id) REFERENCES PARENTS(ID), FOREIGN KEY(owner_id) REFERENCES parents(id)"
      ] do
    test "proven no-FK, implicit PK and redundant matching FK edges retain snapshots: #{reference}",
         %{db: db} do
      sql(db, "CREATE TABLE parents(id TEXT COLLATE NOCASE PRIMARY KEY,reference TEXT)")

      sql(
        db,
        "CREATE TABLE children(id INTEGER PRIMARY KEY,owner_id VARCHAR COLLATE NOCASE,reference TEXT#{unquote(reference)})"
      )

      sql(db, "INSERT INTO parents VALUES('A','left'),('B','right')")
      sql(db, "INSERT INTO children VALUES(1,'A','original')")

      assert {:ok, %CandidateState{rows: [%{"id" => 1, "reference" => "original"}]}} =
               Adapter.load_candidate_state(db, collection_request("a"))

      assert {:ok, %{values: %{"id" => 1, "reference" => "original"}}} =
               Adapter.load_record_state(db, record_request("a"))

      assert :ok = GraphOwnership.validate(db, graph(:binding, "a"), [])
      assert :ok = GraphOwnership.validate(db, graph(:empty_sync, "a"), [])
    end
  end

  test "a physical unique non-PK comparator can prove the parent", %{db: db} do
    sql(db, "CREATE TABLE parents(id TEXT COLLATE NOCASE,reference TEXT)")
    sql(db, "CREATE UNIQUE INDEX parent_identity ON parents(id COLLATE NOCASE)")

    sql(
      db,
      "CREATE TABLE children(id INTEGER PRIMARY KEY,owner_id TEXT COLLATE NOCASE,reference TEXT)"
    )

    sql(db, "INSERT INTO parents VALUES('A','left'),('B','right')")
    sql(db, "INSERT INTO children VALUES(1,'A','original')")
    assert :ok = GraphOwnership.validate(db, graph(:binding, "a"), [])

    assert {:ok, %CandidateState{rows: [_]}} =
             Adapter.load_candidate_state(db, collection_request("a"))
  end

  for index <- [
        "CREATE UNIQUE INDEX identity_idx ON parents(id) WHERE id IS NOT NULL",
        "CREATE UNIQUE INDEX identity_idx ON parents(lower(id))"
      ] do
    test "partial and expression unique indexes do not establish owned identity: #{index}", %{
      db: db
    } do
      sql(db, "CREATE TABLE parents(id TEXT,reference TEXT)")
      sql(db, unquote(index))
      sql(db, "CREATE TABLE children(id INTEGER PRIMARY KEY,owner_id TEXT,reference TEXT)")
      sql(db, "INSERT INTO parents VALUES('A','left'),('B','right')")
      sql(db, "INSERT INTO children VALUES(1,'A','original')")
      refuse_all_ports(db)
    end
  end

  for {definition, suffix, type, left, right} <- [
        {"id INTEGER PRIMARY KEY,reference TEXT", "", "INTEGER", 1, 2},
        {"id INTEGER PRIMARY KEY DESC,reference TEXT", "", "INTEGER", 1, 2},
        {"id TEXT PRIMARY KEY,reference TEXT", " WITHOUT ROWID", "TEXT", "A", "B"}
      ] do
    test "physical PK alternatives retain exact graph and snapshot proof: #{definition}", %{
      db: db
    } do
      sql(db, "CREATE TABLE parents(#{unquote(definition)})#{unquote(suffix)}")

      sql(
        db,
        "CREATE TABLE children(id INTEGER PRIMARY KEY,owner_id #{unquote(type)} REFERENCES parents(id),reference TEXT)"
      )

      sql(db, "INSERT INTO parents VALUES(?,'left'),(?,'right')", [unquote(left), unquote(right)])
      sql(db, "INSERT INTO children VALUES(1,?,'original')", [unquote(left)])
      assert :ok = GraphOwnership.validate(db, graph(:binding, unquote(left)), [])

      assert {:ok, %CandidateState{rows: [_]}} =
               Adapter.load_candidate_state(db, collection_request(unquote(left)))

      assert {:ok, %{values: %{"reference" => "original"}}} =
               Adapter.load_record_state(db, record_request(unquote(left)))
    end
  end

  defp refuse_all_ports(db) do
    before = {sql(db, "SELECT * FROM parents"), sql(db, "SELECT * FROM children")}
    changes = sql(db, "SELECT total_changes()")

    for kind <- [:binding, :empty_sync] do
      assert {:error, %Error{details: %{code: :owned_key_comparison_not_evaluable}}} =
               Adapter.execute_write_unsafe(db, graph(kind, "A"))
    end

    assert {:error, %Error{details: %{code: :owned_key_comparison_not_evaluable}}} =
             Adapter.load_candidate_state(db, collection_request("A"))

    assert {:error, %Error{details: %{code: :owned_key_comparison_not_evaluable}}} =
             Adapter.load_record_state(db, record_request("A"))

    assert before == {sql(db, "SELECT * FROM parents"), sql(db, "SELECT * FROM children")}
    assert changes == sql(db, "SELECT total_changes()")
  end

  defp tables(db, parent_type, child_type, left, right, owner) do
    sql(db, "CREATE TABLE parents(id #{parent_type} PRIMARY KEY,reference TEXT)")

    sql(db, """
    CREATE TABLE children(id INTEGER PRIMARY KEY,owner_id #{child_type} REFERENCES parents(id),reference TEXT)
    """)

    sql(db, "INSERT INTO parents VALUES(?,'left'),(?,'right')", [left, right])
    sql(db, "INSERT INTO children VALUES(1,?,'original')", [owner])
  end

  defp parent(owner) do
    {:ok, command} =
      Command.new(%{
        operation: :update,
        relation: :parents,
        assignments: [%{field: :reference, value: {:literal, "root-write"}}],
        predicate: {:eq, {:field, :id}, {:literal, owner}},
        returning: [:id],
        expected_cardinality: {:exactly, 1}
      })

    command
  end

  defp collection_request(owner) do
    %CandidateRequest{
      operation: :update,
      representation: :delta,
      relationship: "children",
      path: [:children],
      parent_command: parent(owner),
      parent_key: :id,
      child_relation: :children,
      child_key: :owner_id,
      identity_fields: ["id"],
      fields: ["id", "reference"],
      max_rows: 100
    }
  end

  defp record_request(owner) do
    %RecordRequest{
      operation: :update,
      relation: :children,
      predicate: {:eq, {:field, :id}, {:literal, 1}},
      fields: ["id", "reference"],
      ownership: %{parent_command: parent(owner), parent_key: :id, child_key: :owner_id}
    }
  end

  defp graph(kind, owner) do
    root = %Node{
      id: "root",
      path: [],
      relation: :parents,
      strategy: :ordered,
      rows: [%Row{id: "root", path: [], command: parent(owner)}]
    }

    {:ok, child_command} =
      Command.new(%{
        operation: :update,
        relation: :children,
        assignments: [%{field: :reference, value: {:literal, "changed"}}],
        predicate: {:eq, {:field, :id}, {:literal, 1}},
        returning: [:id],
        expected_cardinality: {:exactly, 1}
      })

    child = %Node{
      id: "children",
      path: [:children],
      relation: :children,
      strategy: if(kind == :empty_sync, do: :sync, else: :ordered),
      rows:
        if(kind == :empty_sync,
          do: [],
          else: [
            %Row{
              id: "child",
              path: [:children, 0],
              command: child_command,
              bindings: [
                %Binding{field: :owner_id, from_node: "root", from_row: "root", from_field: :id}
              ]
            }
          ]
        ),
      sync_predicate: {:eq, {:field, :owner_id}, {:generated, "root", "root", :id}},
      identity_fields: [:id],
      delete_missing?: kind == :empty_sync
    }

    {:ok, graph} = Graph.new([root, child], {"root", "root"})
    graph
  end

  defp sql(db, query, params \\ []) do
    {:ok, result} = Adapter.execute(db, query, params, [])
    result.rows
  end
end
