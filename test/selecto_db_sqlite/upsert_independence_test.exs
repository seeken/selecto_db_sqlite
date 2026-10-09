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
