defmodule SelectoDBSQLite.UpsertIndependenceTest do
  use ExUnit.Case, async: false
  alias Selecto.Write.{Batch, Command, Error, UpsertCandidateRequest}
  alias SelectoDBSQLite.Adapter

  @types %{id: :integer, start: :integer, finish: :integer, note: :string}

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(db) end)

    sql(
      db,
      "CREATE TABLE ranges(id INTEGER PRIMARY KEY,start INTEGER,finish INTEGER,note TEXT COLLATE NOCASE DEFAULT 'default')"
    )

    sql(db, "INSERT INTO ranges VALUES(1,5,7,'private'),(2,10,11,'other')")
    sql(db, "CREATE TABLE caller(id INTEGER PRIMARY KEY)")
    sql(db, "INSERT INTO caller VALUES(10)")
    assert rows(db, "PRAGMA temp_store") == [[2]]
    assert Enum.all?(rows(db, "PRAGMA database_list"), fn [_, _, file] -> file == "" end)
    %{db: db}
  end

  test "distinct ordinary insert, update, delete and upsert compose with protected rows", %{
    db: db
  } do
    operations = [
      ordinary(:insert, %{id: 4, start: 30, finish: 31}),
      protected(%{id: 1, finish: 6}),
      ordinary(:update, %{finish: 12}, eq(:id, 2)),
      protected(%{id: 3, start: 20, finish: 21}),
      ordinary(:upsert, %{id: 5, start: 40, finish: 41}),
      ordinary(:delete, %{}, eq(:id, 4))
    ]

    assert {:ok, results} = prepared(db, operations)
    assert length(results) == 6

    assert rows(db, "SELECT id,start,finish FROM ranges ORDER BY id") == [
             [1, 5, 6],
             [2, 10, 12],
             [3, 20, 21],
             [5, 40, 41]
           ]
  end

  test "new protected row cannot be selected by a later ordinary update or delete", %{db: db} do
    for operation <- [:update, :delete], position <- [:before, :after] do
      guarded_refusal(db, fn ->
        protected = protected(%{id: 3, start: 5, finish: 6})

        ordinary =
          ordinary(operation, if(operation == :update, do: %{finish: 0}, else: %{}), eq("ID", 3))

        pair = if position == :before, do: [ordinary, protected], else: [protected, ordinary]
        [ordinary(:insert, %{id: 9, start: 90, finish: 91}) | pair]
      end)
    end
  end

  test "updated protected values can create a match absent from the stored selection", %{db: db} do
    for operation <- [:update, :delete] do
      guarded_refusal(db, fn ->
        [
          protected(%{id: 1, finish: 6}),
          ordinary(
            operation,
            if(operation == :update, do: %{finish: 0}, else: %{}),
            eq(:finish, 6)
          )
        ]
      end)
    end
  end

  test "native NULL and disjoint predicates remain supported for new rows", %{db: db} do
    assert {:ok, _} =
             prepared(db, [
               protected(%{id: 3, start: 5, finish: 6}),
               ordinary(:update, %{finish: 12}, eq(:id, 2)),
               ordinary(:delete, %{}, eq(:note, nil))
             ])

    assert rows(db, "SELECT id,finish FROM ranges ORDER BY id") == [[1, 7], [2, 12], [3, 6]]
  end

  test "native column collation, affinity and RHS fields govern prospective matching", %{db: db} do
    for predicate <- [
          eq(:note, "DEFAULT"),
          eq(:id, "3"),
          {:gt, {:field, :finish}, {:field, :start}}
        ] do
      guarded_refusal(db, fn ->
        [protected(%{id: 3, start: 5, finish: 6}), ordinary(:delete, %{}, predicate)]
      end)
    end

    assert {:ok, _} =
             prepared(db, [
               protected(%{id: 3, start: 5, finish: 6}),
               ordinary(:delete, %{}, eq(:note, "absent"))
             ])

    assert rows(db, "SELECT id FROM ranges ORDER BY id") == [[1], [2], [3]]
  end

  test "an initially empty key-moving update cannot collide after an ordinary insert prefix", %{
    db: db
  } do
    guarded_refusal(db, fn ->
      [
        ordinary(:insert, %{id: 4, start: 5, finish: 6}),
        ordinary(:update, %{"ID" => 3}, eq(:id, 4)),
        protected(%{id: 3, start: 10, finish: 11})
      ]
    end)
  end

  test "unknown consumed volatile defaults cannot prove a prospective predicate", %{db: db} do
    sql(
      db,
      "CREATE TABLE clock_ranges(id INTEGER PRIMARY KEY,start INTEGER,finish INTEGER,note TEXT DEFAULT CURRENT_TIMESTAMP)"
    )

    guarded_refusal(db, fn ->
      [
        protected(%{id: 3, start: 5, finish: 6}, "clock_ranges"),
        ordinary(:delete, %{}, eq(:note, "absent"), "clock_ranges")
      ]
    end)

    assert rows(db, "SELECT * FROM clock_ranges") == []
  end

  test "an index-arbiter insert cannot guess its generated rowid for another UPSERT", %{db: db} do
    name_table(db, false)

    name_refusal(db, [
      {:protected, name_command(%{subject: "new", start: 5, finish: 6}, [:subject], false)},
      name_command(%{id: 3, finish: 0}, [:id], false)
    ])
  end

  test "the other arbiter includes consumed insertion defaults and updated keys", %{db: db} do
    name_table(db, true)

    for protected <- [
          name_command(%{subject: "new", start: 5, finish: 6}, [:subject], true),
          name_command(%{subject: "one", code: "generated", finish: 6}, [:subject], true, [
            :code,
            :finish
          ])
        ] do
      name_refusal(db, [
        {:protected, protected},
        name_command(%{code: "generated", subject: "other", finish: 0}, [:code], true)
      ])
    end
  end

  test "known disjoint other-index keys permit genuine mixed UPSERTs", %{db: db} do
    name_table(db, true)

    assert {:ok, results} =
             name_prepared(db, [
               {:protected,
                name_command(%{subject: "new", start: 5, finish: 6}, [:subject], true)},
               name_command(%{code: "other-code", subject: "other", finish: 0}, [:code], true)
             ])

    assert length(results) == 2

    assert rows(db, "SELECT * FROM names ORDER BY id") == [
             [1, "one", "one-code", 5, 7],
             [2, "two", "two-code", 10, 11],
             [3, "new", "generated", 5, 6],
             [4, "other", "other-code", nil, 0]
           ]
  end

  test "an explicit rowid proves independence under a different rowid arbiter", %{db: db} do
    name_table(db, false)

    assert {:ok, results} =
             name_prepared(db, [
               {:protected,
                name_command(%{id: 3, subject: "new", start: 5, finish: 6}, [:subject], false)},
               name_command(%{id: 4, finish: 0}, [:id], false)
             ])

    assert length(results) == 2

    assert rows(db, "SELECT * FROM names ORDER BY id") == [
             [1, "one", 5, 7],
             [2, "two", 10, 11],
             [3, "new", 5, 6],
             [4, nil, nil, 0]
           ]
  end

  test "two protected index-arbiter inserts retain independent generated rowids", %{db: db} do
    name_table(db, false)

    assert {:ok, results} =
             name_prepared(db, [
               {:protected,
                name_command(%{subject: "new-a", start: 5, finish: 6}, [:subject], false)},
               {:protected,
                name_command(%{subject: "new-b", start: 10, finish: 11}, [:subject], false)}
             ])

    assert length(results) == 2

    assert rows(db, "SELECT * FROM names ORDER BY id") == [
             [1, "one", 5, 7],
             [2, "two", 10, 11],
             [3, "new-a", 5, 6],
             [4, "new-b", 10, 11]
           ]
  end

  test "an unprovable default consumed only by the other arbiter remains pending", %{db: db} do
    name_table(db, true, "CURRENT_TIMESTAMP")

    name_refusal(db, [
      {:protected, name_command(%{subject: "new", start: 5, finish: 6}, [:subject], true)},
      name_command(%{code: "other-code", subject: "other", finish: 0}, [:code], true)
    ])
  end

  defp name_table(db, code?, default \\ "'generated'") do
    if code? do
      sql(
        db,
        "CREATE TABLE names(id INTEGER PRIMARY KEY,subject TEXT UNIQUE,code TEXT UNIQUE DEFAULT #{default},start INTEGER,finish INTEGER)"
      )

      sql(db, "INSERT INTO names VALUES(1,'one','one-code',5,7),(2,'two','two-code',10,11)")
    else
      sql(
        db,
        "CREATE TABLE names(id INTEGER PRIMARY KEY,subject TEXT UNIQUE,start INTEGER,finish INTEGER)"
      )

      sql(db, "INSERT INTO names VALUES(1,'one',5,7),(2,'two',10,11)")
    end
  end

  defp name_command(values, target, code?, mask \\ [:finish]) do
    types = %{id: :integer, subject: :string, start: :integer, finish: :integer}
    types = if code?, do: Map.put(types, :code, :string), else: types

    {:ok, command} =
      Command.new(%{
        operation: :upsert,
        relation: "names",
        assignments:
          Enum.map(values, fn {field, value} -> %{field: field, value: {:literal, value}} end),
        expected_cardinality: :many,
        required_capabilities: [:upsert],
        metadata: %{field_types: types, conflict_target: target, upsert_update_fields: mask}
      })

    command
  end

  defp name_prepared(db, operations) do
    Adapter.execute_prepared_write_unsafe(db, fn loader ->
      commands =
        Enum.map(operations, fn
          {:protected, command} ->
            command = %{command | required_capabilities: [:upsert, :protected_upsert_candidates]}
            subject = make_ref()

            request = %UpsertCandidateRequest{
              command: command,
              field_types: command.metadata.field_types,
              dependencies: [:start, :finish],
              subject: subject
            }

            {:ok, state} = loader.(request)
            assert state.complete? and state.protection == :locked
            assert is_integer(state.values["finish"]) and is_integer(state.values["start"])
            assert state.values["finish"] > state.values["start"]

            %{
              command
              | metadata:
                  Map.merge(command.metadata, %{
                    protected_upsert_receipt: state.receipt,
                    protected_upsert_subject: subject
                  })
            }

          command ->
            command
        end)

      {:ok, batch} = Batch.new(commands)
      {:ok, batch, %{}}
    end)
  end

  defp name_refusal(db, operations) do
    sql(db, "BEGIN")
    sql(db, "INSERT INTO caller VALUES(11)")
    sql(db, "SAVEPOINT original_name_caller")
    before = rows(db, "SELECT * FROM names ORDER BY id")
    :ok = Exqlite.Sqlite3.set_update_hook(db, self())
    drain_hooks()

    {:ok, prefix} =
      Command.new(%{
        operation: :insert,
        relation: "caller",
        assignments: [%{field: :id, value: {:literal, 12}}],
        metadata: %{field_types: %{id: :integer}}
      })

    assert {:error, %Error{details: %{code: :required_data_rule_pending}}} =
             name_prepared(db, [prefix | operations])

    assert rows(db, "SELECT * FROM names ORDER BY id") == before
    assert rows(db, "SELECT * FROM caller ORDER BY id") == [[10], [11]]
    refute_business_hook()
    assert {:ok, :transaction} = Exqlite.Sqlite3.transaction_status(db)
    sql(db, "ROLLBACK TO original_name_caller")
    sql(db, "RELEASE original_name_caller")
    assert rows(db, "SELECT * FROM names ORDER BY id") == before
    assert rows(db, "SELECT * FROM caller ORDER BY id") == [[10], [11]]
    sql(db, "ROLLBACK")
    assert rows(db, "SELECT * FROM caller") == [[10]]
    drain_hooks()
  end

  defp eq(field, value), do: {:eq, {:field, field}, {:literal, value}}

  defp protected(values, table \\ "ranges"),
    do: {:protected, ordinary(:upsert, values, nil, table)}

  defp ordinary(operation, values, predicate \\ nil, table \\ "ranges") do
    {:ok, command} =
      Command.new(%{
        operation: operation,
        relation: table,
        assignments:
          Enum.map(values, fn {field, value} -> %{field: field, value: {:literal, value}} end),
        predicate: predicate,
        expected_cardinality: :many,
        required_capabilities: if(operation == :upsert, do: [:upsert], else: []),
        metadata: %{field_types: @types, conflict_target: [:id], upsert_update_fields: [:finish]}
      })

    command
  end

  defp prepared(db, operations) do
    Adapter.execute_prepared_write_unsafe(db, fn loader ->
      commands =
        Enum.map(operations, fn
          {:protected, command} ->
            command = %{command | required_capabilities: [:upsert, :protected_upsert_candidates]}
            subject = make_ref()

            request = %UpsertCandidateRequest{
              command: command,
              field_types: @types,
              dependencies: [:start, :finish],
              subject: subject
            }

            {:ok, state} = loader.(request)

            %{
              command
              | metadata:
                  Map.merge(command.metadata, %{
                    protected_upsert_receipt: state.receipt,
                    protected_upsert_subject: subject
                  })
            }

          command ->
            command
        end)

      {:ok, batch} = Batch.new(commands)
      {:ok, batch, %{}}
    end)
  end

  defp guarded_refusal(db, operations) do
    sql(db, "BEGIN")
    sql(db, "INSERT INTO caller VALUES(11)")
    sql(db, "SAVEPOINT caller_proof")
    before = rows(db, "SELECT * FROM ranges ORDER BY id")
    :ok = Exqlite.Sqlite3.set_update_hook(db, self())
    drain_hooks()

    assert {:error, %Error{details: %{code: :required_data_rule_pending}}} =
             prepared(db, operations.())

    assert rows(db, "SELECT * FROM ranges ORDER BY id") == before
    assert rows(db, "SELECT * FROM caller ORDER BY id") == [[10], [11]]
    refute_business_hook()
    assert {:ok, :transaction} = Exqlite.Sqlite3.transaction_status(db)
    sql(db, "ROLLBACK TO caller_proof")
    sql(db, "RELEASE caller_proof")
    sql(db, "ROLLBACK")
    assert rows(db, "SELECT * FROM caller") == [[10]]
    drain_hooks()
  end

  defp drain_hooks do
    receive do
      {action, _, _, _} when action in [:insert, :update, :delete] -> drain_hooks()
    after
      0 -> :ok
    end
  end

  defp refute_business_hook do
    receive do
      {action, "main", table, _} when action in [:insert, :update, :delete] ->
        flunk("unexpected business DML on #{table}")

      {_, "temp", _, _} ->
        refute_business_hook()
    after
      0 -> :ok
    end
  end

  defp sql(db, query), do: assert({:ok, _} = Adapter.execute(db, query, [], []))

  defp rows(db, query) do
    {:ok, %{rows: rows}} = Adapter.execute(db, query, [], [])
    rows
  end
end
