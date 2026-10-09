defmodule SelectoDBSQLite.UpsertCandidateSafetyTest do
  use ExUnit.Case, async: false

  alias Selecto.Write.{Command, Error, Graph, UpsertCandidateRequest}
  alias Selecto.Write.Graph.{Node, Row}
  alias SelectoDBSQLite.Adapter

  @types %{id: :integer, start: :decimal, finish: :decimal}

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(db) end)
    sql(db, "CREATE TABLE ranges(id INTEGER PRIMARY KEY,start NUMERIC,finish NUMERIC)")
    sql(db, "INSERT INTO ranges VALUES(1,5,7),(2,10,11)")
    sql(db, "CREATE TABLE caller(id INTEGER PRIMARY KEY,note TEXT)")
    sql(db, "INSERT INTO caller VALUES(10,'committed')")
    assert_memory(db)
    %{db: db}
  end

  test "same-table implicit cleanup refuses before root DML and preserves caller ownership", %{
    db: db
  } do
    caller(db)
    before = snapshot(db)
    observe(db)

    assert_pending(
      Adapter.execute_prepared_write_unsafe(db, fn loader ->
        with {:ok, final} <- prepare(loader, command("ranges", %{id: 1, finish: Decimal.new(6)})) do
          graph(final, "ranges", {:eq, {:field, :id}, {:literal, 1}})
        end
      end)
    )

    assert snapshot(db) == before
    assert business_hooks() == []
    assert_caller(db)
  end

  test "unrelated-table cleanup retains actual protected graph execution", %{db: db} do
    sql(db, "CREATE TABLE notes(id INTEGER PRIMARY KEY,note TEXT)")
    sql(db, "INSERT INTO notes VALUES(1,'remove'),(2,'keep')")

    assert {:ok, result} =
             Adapter.execute_prepared_write_unsafe(db, fn loader ->
               with {:ok, final} <-
                      prepare(loader, command("ranges", %{id: 1, finish: Decimal.new(6)})) do
                 graph(final, "notes", {:eq, {:field, :id}, {:literal, 1}})
               end
             end)

    assert result.operation == :graph
    assert result.affected_rows == 2
    assert rows(db, "SELECT * FROM ranges ORDER BY id") == [[1, 5, 6], [2, 10, 11]]
    assert rows(db, "SELECT * FROM notes ORDER BY id") == [[2, "keep"]]
  end

  test "protected UPSERT retains ordinary physical target fences", %{db: db} do
    sql(db, "CREATE TABLE audit(id INTEGER)")

    for {table, extra} <- [
          {"main_trigger", ""},
          {"temp_trigger", ""},
          {"generated_target", ",derived NUMERIC GENERATED ALWAYS AS(start+1) VIRTUAL"},
          {"shadow_target", ""},
          {"rollback_target", ""}
        ] do
      start =
        if table == "rollback_target",
          do: "NUMERIC NOT NULL ON CONFLICT ROLLBACK",
          else: "NUMERIC"

      sql(
        db,
        "CREATE TABLE #{table}(id INTEGER PRIMARY KEY,start #{start},finish NUMERIC#{extra})"
      )

      sql(db, "INSERT INTO #{table}(id,start,finish) VALUES(1,5,7)")
    end

    sql(
      db,
      "CREATE TRIGGER ordinary_target_trigger AFTER INSERT ON main_trigger BEGIN INSERT INTO audit VALUES(new.id); END"
    )

    sql(
      db,
      "CREATE TEMP TRIGGER temporary_target_trigger AFTER INSERT ON main.temp_trigger BEGIN INSERT INTO audit VALUES(new.id); END"
    )

    sql(db, "CREATE TEMP TABLE SHADOW_TARGET(id INTEGER,start NUMERIC,finish NUMERIC)")
    caller(db)
    before = snapshot(db)
    observe(db)

    for table <- [
          "main_trigger",
          "temp_trigger",
          "generated_target",
          "shadow_target",
          "rollback_target"
        ] do
      values = %{
        id: 3,
        start: if(table == "rollback_target", do: nil, else: Decimal.new(5)),
        finish: Decimal.new(6)
      }

      assert_pending(execute(db, command(table, values)))
      assert rows(db, "SELECT id,start,finish FROM main.#{table}") == [[1, 5, 7]]
      assert rows(db, "SELECT * FROM audit") == []
      assert snapshot(db) == before
      assert business_hooks() == []
    end

    assert_caller(db)
  end

  test "ignored insert-only values still encounter actual INSERT constraints", %{db: db} do
    sql(
      db,
      "CREATE TABLE strict_ranges(id INTEGER PRIMARY KEY,start NUMERIC NOT NULL,finish NUMERIC)"
    )

    sql(db, "INSERT INTO strict_ranges VALUES(1,5,7)")
    caller(db)
    before = snapshot(db)
    observe(db)

    assert {:error,
            %Error{type: :native_constraint_violation, details: %{category: :not_null_violation}}} =
             execute(db, command("strict_ranges", %{id: 1, start: nil, finish: Decimal.new(6)}))

    assert rows(db, "SELECT * FROM strict_ranges") == [[1, 5, 7]]
    assert snapshot(db) == before
    assert business_hooks() == []
    assert_caller(db)
  end

  test "DO UPDATE still obeys other native unique constraints and preserves caller work", %{
    db: db
  } do
    sql(
      db,
      "CREATE TABLE unique_ranges(id INTEGER PRIMARY KEY,start NUMERIC,finish NUMERIC,secret TEXT UNIQUE)"
    )

    sql(db, "INSERT INTO unique_ranges VALUES(1,5,7,'a'),(2,10,11,'b')")
    caller(db)
    before = snapshot(db)
    observe(db)

    command =
      command(
        "unique_ranges",
        %{id: 1, finish: Decimal.new(6), secret: "b"},
        [:finish, :secret],
        Map.put(@types, :secret, :string)
      )

    assert {:error,
            %Error{type: :native_constraint_violation, details: %{category: :unique_violation}}} =
             execute(db, command)

    assert rows(db, "SELECT * FROM unique_ranges ORDER BY id") == [
             [1, 5, 7, "a"],
             [2, 10, 11, "b"]
           ]

    assert snapshot(db) == before
    assert business_hooks() == []
    assert_caller(db)
  end

  test "a trusted prepare callback cannot silently replace the witnessed prior row", %{db: db} do
    caller(db)
    before = snapshot(db)
    observe(db)

    assert_pending(
      Adapter.execute_prepared_write_unsafe(db, fn loader ->
        with {:ok, final} <- prepare(loader, command("ranges", %{id: 1, finish: Decimal.new(6)})) do
          # This is the trusted callback's own explicit SQL, not generated UPSERT.
          sql(db, "UPDATE ranges SET start=100 WHERE id=1")
          {:ok, final, %{}}
        end
      end)
    )

    assert snapshot(db) == before
    assert business_hooks() == [{:update, "ranges", 1}]
    assert_caller(db)
  end

  test "caller DEFERRED transaction witnesses block a competing shared-memory writer" do
    database =
      "file:selecto-protected-upsert-deferred-#{System.unique_integer([:positive])}?mode=memory&cache=shared"

    {:ok, first} = Adapter.connect(database: database, temp_store: :memory, busy_timeout: 0)
    {:ok, second} = Adapter.connect(database: database, temp_store: :memory, busy_timeout: 0)

    on_exit(fn ->
      Adapter.disconnect(first)
      Adapter.disconnect(second)
    end)

    for db <- [first, second], do: assert_memory(db)
    sql(first, "CREATE TABLE ranges(id INTEGER PRIMARY KEY,start NUMERIC,finish NUMERIC)")
    sql(first, "INSERT INTO ranges VALUES(1,5,7)")
    sql(first, "CREATE TABLE caller(id INTEGER PRIMARY KEY,note TEXT)")
    sql(first, "INSERT INTO caller VALUES(10,'committed')")
    sql(first, "BEGIN DEFERRED")
    sql(first, "SAVEPOINT original_caller")
    assert rows(first, "SELECT * FROM caller") == [[10, "committed"]]

    assert {:ok, _} =
             Adapter.execute_prepared_write_unsafe(first, fn loader ->
               with {:ok, final} <-
                      prepare(loader, command("ranges", %{id: 1, finish: Decimal.new(6)})) do
                 # No outer main-database write preceded the witness. The second actual
                 # connection must not replace its row while this read transaction owns it.
                 assert {:error, %Error{}} = Adapter.execute_write_unsafe(second, plain_insert(2))
                 assert rows(first, "SELECT * FROM ranges") == [[1, 5, 7]]
                 {:ok, final, %{}}
               end
             end)

    assert Exqlite.Sqlite3.transaction_status(first) == {:ok, :transaction}
    assert rows(first, "SELECT * FROM ranges") == [[1, 5, 6]]
    sql(first, "ROLLBACK TO original_caller")
    sql(first, "RELEASE original_caller")
    assert rows(first, "SELECT * FROM ranges") == [[1, 5, 7]]
    sql(first, "INSERT INTO caller VALUES(11,'later outer work')")
    sql(first, "COMMIT")

    assert rows(second, "SELECT * FROM caller ORDER BY id") == [
             [10, "committed"],
             [11, "later outer work"]
           ]

    assert rows(second, "SELECT * FROM ranges") == [[1, 5, 7]]
    assert {:ok, _} = Adapter.execute_write_unsafe(second, plain_insert(2))
    assert rows(first, "SELECT * FROM ranges ORDER BY id") == [[1, 5, 7], [2, 10, 11]]
  end

  test "duplicate-key indexes do not impersonate a differently sized target", %{db: db} do
    sql(
      db,
      "CREATE TABLE names(id INTEGER PRIMARY KEY,name TEXT UNIQUE,start NUMERIC,finish NUMERIC)"
    )

    sql(db, "CREATE UNIQUE INDEX duplicated_key ON names(name,name)")
    sql(db, "INSERT INTO names VALUES(1,'a',5,7)")
    types = Map.put(@types, :name, :string)

    command =
      command(
        "names",
        %{id: 2, name: "a", start: Decimal.new(100), finish: Decimal.new(6)},
        [:finish],
        types,
        [:name]
      )

    assert {:ok, _} = execute(db, command)
    assert rows(db, "SELECT * FROM names") == [[1, "a", 5, 6]]
  end

  defp graph(command, cleanup_relation, predicate) do
    root = %Node{
      id: "root",
      path: [],
      relation: command.relation,
      strategy: :ordered,
      rows: [%Row{id: "row", path: [], command: command}]
    }

    cleanup = %Node{
      id: "cleanup",
      path: ["cleanup"],
      relation: cleanup_relation,
      strategy: :sync,
      rows: [],
      identity_fields: [:id],
      sync_predicate: predicate,
      delete_missing?: true
    }

    with {:ok, graph} <- Graph.new([root, cleanup], {"root", "row"}), do: {:ok, graph, %{}}
  end

  defp execute(db, command) do
    Adapter.execute_prepared_write_unsafe(db, fn loader ->
      with {:ok, final} <- prepare(loader, command), do: {:ok, final, %{}}
    end)
  end

  defp prepare(loader, command) do
    subject = make_ref()

    request = %UpsertCandidateRequest{
      command: command,
      field_types: command.metadata.field_types,
      dependencies: [:start, :finish],
      subject: subject
    }

    with {:ok, state} <- loader.(request) do
      {:ok,
       %{
         command
         | metadata:
             Map.merge(
               command.metadata,
               %{protected_upsert_receipt: state.receipt, protected_upsert_subject: subject}
             )
       }}
    end
  end

  defp command(relation, values, mask \\ [:finish], types \\ @types, target \\ [:id]) do
    {:ok, command} =
      Command.new(%{
        operation: :upsert,
        relation: relation,
        assignments:
          Enum.map(values, fn {field, value} -> %{field: field, value: {:literal, value}} end),
        required_capabilities: [:upsert, :protected_upsert_candidates],
        metadata: %{conflict_target: target, upsert_update_fields: mask, field_types: types}
      })

    command
  end

  defp plain_insert(id) do
    {:ok, command} =
      Command.new(%{
        operation: :insert,
        relation: "ranges",
        assignments: [
          %{field: :id, value: {:literal, id}},
          %{field: :start, value: {:literal, 10}},
          %{field: :finish, value: {:literal, 11}}
        ]
      })

    command
  end

  defp caller(db) do
    sql(db, "BEGIN DEFERRED")
    sql(db, "INSERT INTO caller VALUES(11,'outer sentinel')")
    sql(db, "SAVEPOINT original_caller")
  end

  defp assert_caller(db) do
    assert Exqlite.Sqlite3.transaction_status(db) == {:ok, :transaction}

    assert rows(db, "SELECT * FROM caller ORDER BY id") == [
             [10, "committed"],
             [11, "outer sentinel"]
           ]

    sql(db, "ROLLBACK TO original_caller")
    sql(db, "RELEASE original_caller")
    sql(db, "ROLLBACK")
    assert rows(db, "SELECT * FROM caller") == [[10, "committed"]]
  end

  defp assert_memory(db) do
    assert Enum.all?(rows(db, "PRAGMA database_list"), fn [_seq, _name, filename] ->
             filename == ""
           end)

    assert rows(db, "PRAGMA temp_store") == [[2]]
  end

  defp snapshot(db),
    do:
      {rows(db, "SELECT * FROM ranges ORDER BY id"), rows(db, "SELECT * FROM caller ORDER BY id")}

  defp assert_pending(result),
    do: assert(match?({:error, %Error{details: %{code: :required_data_rule_pending}}}, result))

  defp observe(db) do
    business_hooks()
    :ok = Exqlite.Sqlite3.set_update_hook(db, self())
  end

  defp business_hooks(acc \\ []) do
    receive do
      {action, "main", table, rowid} when action in [:insert, :update, :delete] ->
        business_hooks([{action, table, rowid} | acc])

      {_action, "temp", _table, _rowid} ->
        business_hooks(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp sql(db, query), do: assert({:ok, _} = Adapter.execute(db, query, [], []))

  defp rows(db, query) do
    {:ok, %{rows: rows}} = Adapter.execute(db, query, [], [])
    rows
  end
end
