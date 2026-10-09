defmodule SelectoDBSQLite.UpsertCandidateTest do
  use ExUnit.Case, async: false

  alias Selecto.Write.{Batch, Command, Error, UpsertCandidateRequest, UpsertCandidateState}
  alias SelectoDBSQLite.Adapter

  @types %{id: :integer, start: :decimal, finish: :decimal, secret: :string}

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(db) end)

    sql(
      db,
      "CREATE TABLE ranges(id INTEGER PRIMARY KEY,start NUMERIC,finish NUMERIC,secret TEXT DEFAULT 'default')"
    )

    sql(db, "INSERT INTO ranges VALUES(1,5,7,'private'),(2,10,11,'other')")
    %{db: db}
  end

  test "existing candidate follows only the native update whitelist and keeps insert intent", %{
    db: db
  } do
    command =
      command(%{id: 1, start: Decimal.new(100), finish: Decimal.new(6), secret: "attempted"}, [
        :finish
      ])

    assert {:ok, _} = prepared(db, [command])

    assert_receive {:candidate,
                    %UpsertCandidateState{
                      branch: :conflict,
                      effect: :update,
                      values: values,
                      prior_values: prior
                    }}

    assert Decimal.equal?(values["start"], Decimal.new(5))
    assert Decimal.equal?(values["finish"], Decimal.new(6))
    assert values["secret"] == "private"
    assert prior["secret"] == "private"

    assert rows(db, "SELECT * FROM ranges ORDER BY id") == [
             [1, 5, 6, "private"],
             [2, 10, 11, "other"]
           ]
  end

  test "new branch supplies known NULL dependencies while unconsumed default remains native", %{
    db: db
  } do
    assert {:ok, _} =
             prepared(db, [command(%{id: 3, start: Decimal.new(5)}, [:start])], [:start, :finish])

    assert_receive {:candidate,
                    %{branch: :insert, effect: :insert, values: values, prior_values: %{}}}

    assert values["finish"] == nil
    assert not Map.has_key?(values, "secret")
    assert rows(db, "SELECT * FROM ranges WHERE id=3") == [[3, 5, nil, "default"]]
  end

  test "consumed constant default is projected while actual INSERT retains its omission", %{
    db: db
  } do
    assert {:ok, _} =
             prepared(
               db,
               [command(%{id: 3, start: Decimal.new(5), finish: Decimal.new(6)}, [:finish])],
               [:secret]
             )

    assert_receive {:candidate, %{branch: :insert, values: values}}
    assert values["secret"] == "default"
    assert rows(db, "SELECT * FROM ranges WHERE id=3") == [[3, 5, 6, "default"]]
  end

  test "consumed volatile defaults refuse and preserve a caller transaction and savepoint", %{
    db: db
  } do
    for {table, default} <- [
          {"volatile_clock", "CURRENT_TIMESTAMP"},
          {"volatile_random", "(random())"}
        ] do
      sql(
        db,
        "CREATE TABLE #{table}(id INTEGER PRIMARY KEY,start NUMERIC,finish NUMERIC,secret TEXT DEFAULT #{default})"
      )
    end

    caller(db)
    before = snapshot(db)
    observe_business(db)

    for table <- ["volatile_clock", "volatile_random"] do
      assert_pending(
        prepared(
          db,
          [
            command(
              %{id: 3, start: Decimal.new(5), finish: Decimal.new(6)},
              [:finish],
              {:exactly, 1},
              table
            )
          ],
          [:secret]
        )
      )

      assert rows(db, "SELECT * FROM #{table}") == []
    end

    assert snapshot(db) == before
    refute_business_hook()
    assert_caller(db)
  end

  test "verified literal default grammar retains SQLite values and affinity", %{db: db} do
    literals = [
      {"NULL", "NUMERIC", :decimal, nil, nil},
      {"TRUE", "BOOLEAN", :boolean, true, 1},
      {"FALSE", "BOOLEAN", :boolean, false, 0},
      {"((-12.5e1))", "NUMERIC", :decimal, Decimal.new(-125), -125},
      {"(+0x10)", "NUMERIC", :decimal, Decimal.new(16), 16},
      {"(('a)''b'))", "TEXT", :string, "a)'b", "a)'b"},
      {"('1e-400')", "NUMERIC", :decimal, Decimal.new(0), 0}
    ]

    for {{literal, physical, type, expected, stored}, index} <- Enum.with_index(literals) do
      table = "literal_defaults_#{index}"

      sql(
        db,
        "CREATE TABLE #{table}(id INTEGER PRIMARY KEY,marker #{physical} DEFAULT #{literal})"
      )

      types = %{id: :integer, marker: type}

      assert {:ok, _} =
               prepared(db, [command(%{id: 1}, [], {:exactly, 1}, table, [:id], types)], [:marker])

      assert_receive {:candidate, %{branch: :insert, values: values}}
      assert values["marker"] == expected
      assert rows(db, "SELECT marker FROM #{table}") == [[stored]]
    end
  end

  test "empty update mask is actual DO NOTHING with existing-state candidate", %{db: db} do
    assert {:ok, _} =
             prepared(db, [command(%{id: 1, start: Decimal.new(100)}, [], {:at_most, 1})])

    assert_receive {:candidate, %{branch: :conflict, effect: :nothing, values: values}}
    assert Decimal.equal?(values["start"], Decimal.new(5))
    assert rows(db, "SELECT start,finish FROM ranges WHERE id=1") == [[5, 7]]
  end

  test "distinct protected physical rows and distinct absent keys compose atomically", %{db: db} do
    commands = [
      command(%{id: 1, finish: Decimal.new(6)}, [:finish]),
      command(%{id: 2, finish: Decimal.new(12)}, [:finish]),
      command(%{id: 3, start: Decimal.new(20), finish: Decimal.new(21)}, [:finish]),
      command(%{id: 4, start: Decimal.new(30), finish: Decimal.new(31)}, [:finish])
    ]

    assert {:ok, results} = prepared(db, commands)
    assert length(results) == 4

    assert rows(db, "SELECT id,start,finish FROM ranges ORDER BY id") == [
             [1, 5, 6],
             [2, 10, 12],
             [3, 20, 21],
             [4, 30, 31]
           ]
  end

  test "repeated physical and absent conflict identities refuse before a safe prefix", %{db: db} do
    for id <- [1, 9] do
      caller(db)
      before = snapshot(db)
      observe_business(db)

      commands = [
        command(%{id: 3, start: Decimal.new(20), finish: Decimal.new(21)}, [:finish]),
        command(%{id: id, start: Decimal.new(5), finish: Decimal.new(6)}, [:finish]),
        command(%{id: id, start: Decimal.new(5), finish: Decimal.new(7)}, [:finish])
      ]

      assert_pending(prepared(db, commands))
      assert snapshot(db) == before
      refute_business_hook()
      assert_caller(db)
    end
  end

  test "unknown generated rowid cannot invalidate a later explicit protected identity", %{db: db} do
    caller(db)
    before = snapshot(db)
    observe_business(db)

    commands = [
      command(%{id: nil, start: Decimal.new(20), finish: Decimal.new(21)}, [:finish]),
      command(%{id: 3, start: Decimal.new(30), finish: Decimal.new(31)}, [:finish])
    ]

    assert_pending(prepared(db, commands))
    assert snapshot(db) == before
    refute_business_hook()
    assert_caller(db)
  end

  test "index collation rather than column collation selects the conflicting row", %{db: db} do
    sql(
      db,
      "CREATE TABLE names(id INTEGER PRIMARY KEY,subject TEXT COLLATE BINARY,start NUMERIC,finish NUMERIC)"
    )

    sql(db, "CREATE UNIQUE INDEX names_key ON names(subject COLLATE NOCASE)")
    sql(db, "INSERT INTO names VALUES(1,'a',5,7)")
    types = %{id: :integer, subject: :string, start: :decimal, finish: :decimal}

    command =
      command(
        %{id: 2, subject: "A", start: Decimal.new(100), finish: Decimal.new(6)},
        [:finish],
        {:exactly, 1},
        "names",
        [:subject],
        types
      )

    assert {:ok, _} = prepared(db, [command])
    assert_receive {:candidate, %{branch: :conflict, values: values}}
    assert values["id"] == 1
    assert values["subject"] == "a"
    assert rows(db, "SELECT * FROM names") == [[1, "a", 5, 6]]
  end

  test "different matching index comparators refuse regardless of creation order", %{db: db} do
    for {table, order} <- [{"names_a", ["BINARY", "NOCASE"]}, {"names_b", ["NOCASE", "BINARY"]}] do
      sql(
        db,
        "CREATE TABLE #{table}(id INTEGER PRIMARY KEY,subject TEXT,start NUMERIC,finish NUMERIC)"
      )

      for {coll, index} <- Enum.with_index(order),
          do:
            sql(db, "CREATE UNIQUE INDEX #{table}_#{index} ON #{table}(subject COLLATE #{coll})")

      sql(db, "INSERT INTO #{table} VALUES(1,'a',5,7)")
      types = %{id: :integer, subject: :string, start: :decimal, finish: :decimal}

      command =
        command(
          %{id: 2, subject: "A", start: Decimal.new(10), finish: Decimal.new(11)},
          [:finish],
          {:exactly, 1},
          table,
          [:subject],
          types
        )

      assert_pending(prepared(db, [command]))
      assert rows(db, "SELECT * FROM #{table}") == [[1, "a", 5, 7]]
    end
  end

  test "native insertion affinity precedes arbiter lookup", %{db: db} do
    sql(
      db,
      "CREATE TABLE numeric_keys(id INTEGER PRIMARY KEY,key_value NUMERIC UNIQUE,start NUMERIC,finish NUMERIC)"
    )

    sql(db, "INSERT INTO numeric_keys VALUES(1,0,5,7)")
    types = %{id: :integer, key_value: :decimal, start: :decimal, finish: :decimal}

    command =
      command(
        %{
          id: 2,
          key_value: Decimal.new("1e-400"),
          start: Decimal.new(100),
          finish: Decimal.new(6)
        },
        [:finish],
        {:exactly, 1},
        "numeric_keys",
        [:key_value],
        types
      )

    assert {:ok, _} = prepared(db, [command])
    assert_receive {:candidate, %{branch: :conflict, values: values}}
    assert values["id"] == 1
    assert Decimal.equal?(values["key_value"], Decimal.new(0))
    assert rows(db, "SELECT * FROM numeric_keys") == [[1, 0, 5, 6]]
  end

  test "NULL in a nullable composite unique key is an insertion, not a row match", %{db: db} do
    sql(
      db,
      "CREATE TABLE nullable_keys(id INTEGER PRIMARY KEY,a TEXT,b INTEGER,start NUMERIC,finish NUMERIC,UNIQUE(a,b))"
    )

    sql(db, "INSERT INTO nullable_keys VALUES(1,NULL,7,5,7)")
    types = %{id: :integer, a: :string, b: :integer, start: :decimal, finish: :decimal}

    command =
      command(
        %{id: 2, a: nil, b: 7, start: Decimal.new(10), finish: Decimal.new(11)},
        [:finish],
        {:exactly, 1},
        "nullable_keys",
        [:a, :b],
        types
      )

    assert {:ok, _} = prepared(db, [command])
    assert_receive {:candidate, %{branch: :insert, effect: :insert}}
    assert rows(db, "SELECT id,a,b FROM nullable_keys ORDER BY id") == [[1, nil, 7], [2, nil, 7]]
  end

  test "receipt tamper, context replacement, and post-transaction reuse cannot authorize DML", %{
    db: db
  } do
    for change <- [:command, :context] do
      caller(db)
      before = snapshot(db)
      observe_business(db)

      assert_pending(
        Adapter.execute_prepared_write_unsafe(db, fn loader ->
          command = command(%{id: 1, finish: Decimal.new(6)}, [:finish])
          {:ok, final, state} = prepare(loader, command, [:start, :finish], %{})
          send(self(), {:retained_receipt, final, state})

          if change == :command,
            do:
              {:ok,
               %{
                 final
                 | assignments:
                     final.assignments ++ [%{field: :secret, value: {:literal, "forged"}}]
               }, %{}},
            else: {:ok, final, %{tenant_id: 7}}
        end)
      )

      assert snapshot(db) == before
      refute_business_hook()
      assert_caller(db)
      assert_receive {:retained_receipt, final, _state}
      assert_pending(Adapter.execute_write_unsafe(db, final))
      assert rows(db, "SELECT secret FROM ranges WHERE id=1") == [["private"]]
    end
  end

  test "reprojection keeps subject and witness but invalidates the older receipt", %{db: db} do
    command = command(%{id: 1, finish: Decimal.new(6)}, [:finish])

    assert {:ok, _} =
             Adapter.execute_prepared_write_unsafe(db, fn loader ->
               subject = make_ref()

               request = %UpsertCandidateRequest{
                 command: command,
                 field_types: @types,
                 dependencies: [:start, :finish],
                 subject: subject
               }

               {:ok, state} = loader.(request)
               {:ok, next} = loader.(%{request | prior: state.receipt})
               assert next.prior_values == state.prior_values
               assert next.receipt != state.receipt
               {:ok, attach(command, next.receipt, subject), %{}}
             end)

    assert rows(db, "SELECT finish FROM ranges WHERE id=1") == [[6]]
  end

  defp command(
         values,
         fields,
         cardinality \\ {:exactly, 1},
         relation \\ "ranges",
         target \\ [:id],
         types \\ @types
       ) do
    {:ok, command} =
      Command.new(%{
        operation: :upsert,
        relation: relation,
        assignments:
          Enum.map(values, fn {field, value} -> %{field: field, value: {:literal, value}} end),
        expected_cardinality: cardinality,
        required_capabilities: [:upsert, :protected_upsert_candidates],
        metadata: %{conflict_target: target, upsert_update_fields: fields, field_types: types}
      })

    command
  end

  defp prepared(db, commands, dependencies \\ [:start, :finish]) do
    Adapter.execute_prepared_write_unsafe(db, fn loader ->
      result =
        Enum.reduce_while(commands, {:ok, []}, fn command, {:ok, finals} ->
          case prepare(loader, command, dependencies, %{}) do
            {:ok, final, state} ->
              send(self(), {:candidate, state})
              {:cont, {:ok, finals ++ [final]}}

            error ->
              {:halt, error}
          end
        end)

      case result do
        {:ok, [final]} ->
          {:ok, final, %{}}

        {:ok, finals} ->
          {:ok, batch} = Batch.new(finals)
          {:ok, batch, %{}}

        error ->
          error
      end
    end)
  end

  defp prepare(loader, command, dependencies, context) do
    subject = make_ref()

    request = %UpsertCandidateRequest{
      command: command,
      field_types: command.metadata.field_types,
      dependencies: dependencies,
      context: context,
      subject: subject
    }

    with {:ok, state} <- loader.(request),
         do: {:ok, attach(command, state.receipt, subject), state}
  end

  defp attach(command, receipt, subject),
    do: %{
      command
      | metadata:
          Map.merge(command.metadata, %{
            protected_upsert_receipt: receipt,
            protected_upsert_subject: subject
          })
    }

  defp caller(db) do
    sql(db, "CREATE TABLE IF NOT EXISTS caller(id INTEGER PRIMARY KEY,note TEXT)")
    sql(db, "INSERT OR IGNORE INTO caller VALUES(10,'committed')")
    sql(db, "BEGIN")
    sql(db, "INSERT INTO caller VALUES(11,'outer sentinel')")
    sql(db, "SAVEPOINT original_caller")
  end

  defp assert_caller(db) do
    assert rows(db, "SELECT * FROM caller ORDER BY id") == [
             [10, "committed"],
             [11, "outer sentinel"]
           ]

    sql(db, "ROLLBACK TO original_caller")
    sql(db, "RELEASE original_caller")
    sql(db, "ROLLBACK")
    assert rows(db, "SELECT * FROM caller") == [[10, "committed"]]
  end

  defp snapshot(db),
    do:
      {rows(db, "SELECT * FROM ranges ORDER BY id"), rows(db, "SELECT * FROM caller ORDER BY id")}

  defp observe_business(db) do
    drain_hooks()
    :ok = Exqlite.Sqlite3.set_update_hook(db, self())
  end

  defp drain_hooks do
    receive do
      {action, _database, _table, _row} when action in [:insert, :update, :delete] ->
        drain_hooks()
    after
      0 -> :ok
    end
  end

  defp refute_business_hook do
    receive do
      {action, "main", table, _} when action in [:insert, :update, :delete] ->
        flunk("unexpected business DML hook on #{table}")

      {_action, "temp", _table, _} ->
        refute_business_hook()
    after
      0 -> :ok
    end
  end

  defp assert_pending(result),
    do:
      assert(
        match?(
          {:error, %Error{details: %{code: code}}}
          when code in [:required_data_rule_pending, :ambiguous_candidate_identity],
          result
        )
      )

  defp sql(db, query), do: assert({:ok, _} = Adapter.execute(db, query, [], []))

  defp rows(db, query) do
    {:ok, %{rows: rows}} = Adapter.execute(db, query, [], [])
    rows
  end
end
