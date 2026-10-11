defmodule SelectoDBSQLite.SharedCacheIsolationTest do
  use ExUnit.Case, async: false

  alias Selecto.Write.{Command, Error, RecordRequest, UpsertCandidateRequest}
  alias SelectoDBSQLite.Adapter

  @types %{id: :integer, start: :decimal, finish: :decimal}

  setup do
    database =
      "file:selecto-shared-cache-isolation-#{System.unique_integer([:positive])}?mode=memory&cache=shared"

    {:ok, first} = Adapter.connect(database: database, temp_store: :memory, busy_timeout: 0)
    {:ok, second} = Adapter.connect(database: database, temp_store: :memory, busy_timeout: 0)

    on_exit(fn ->
      Adapter.disconnect(first)
      Adapter.disconnect(second)
    end)

    for db <- [first, second] do
      assert rows(db, "PRAGMA database_list") == [[0, "main", ""]]
    end

    sql(first, "CREATE TABLE ranges(id INTEGER PRIMARY KEY,start NUMERIC,finish NUMERIC)")
    sql(first, "INSERT INTO ranges VALUES(1,5,7)")
    %{first: first, second: second}
  end

  # The protected witness in a caller-owned DEFERRED transaction rests on this
  # SQLite behaviour: BEGIN IMMEDIATE opens its write transaction before the
  # nested BEGIN is refused. Without it, read_uncommitted skips table read-locks
  # and another shared-cache connection commits under the witness.
  test "nested BEGIN refusal opens the shared-cache write transaction even when reading uncommitted",
       %{first: first, second: second} do
    sql(first, "PRAGMA read_uncommitted=1")

    sql(first, "BEGIN DEFERRED")
    assert rows(first, "SELECT * FROM ranges") == [[1, 5, 7]]
    sql(second, "UPDATE ranges SET start=100 WHERE id=1")
    assert rows(first, "SELECT * FROM ranges") == [[1, 100, 7]]
    sql(first, "ROLLBACK")

    sql(second, "UPDATE ranges SET start=5 WHERE id=1")
    sql(first, "BEGIN DEFERRED")
    sql(first, "SAVEPOINT original_caller")

    assert {:error, "cannot start a transaction within a transaction"} =
             Adapter.execute(first, "BEGIN IMMEDIATE", [], [])

    assert rows(first, "SELECT * FROM ranges") == [[1, 5, 7]]
    assert {:error, _} = Adapter.execute(second, "UPDATE ranges SET start=100 WHERE id=1", [], [])
    assert {:error, _} = Adapter.execute(second, "INSERT INTO ranges VALUES(2,1,2)", [], [])
    assert Exqlite.Sqlite3.transaction_status(first) == {:ok, :transaction}
    sql(first, "RELEASE original_caller")
    sql(first, "ROLLBACK")
    assert rows(second, "SELECT * FROM ranges") == [[1, 5, 7]]
  end

  test "caller DEFERRED and adapter-owned committed-read witnesses block competing writers", %{
    first: first,
    second: second
  } do
    for owner <- [:caller, :adapter] do
      if owner == :caller, do: caller(first)

      assert {:ok, _} =
               Adapter.execute_prepared_write_unsafe(first, fn loader ->
                 with {:ok, final} <- prepare(loader, upsert(%{id: 1, finish: Decimal.new(6)})) do
                   assert {:error, _} =
                            Adapter.execute(
                              second,
                              "UPDATE ranges SET start=100 WHERE id=1",
                              [],
                              []
                            )

                   {:ok, final, %{}}
                 end
               end)

      assert rows(first, "SELECT * FROM ranges") == [[1, 5, 6]]

      if owner == :caller do
        assert_caller(first)
        assert rows(first, "SELECT * FROM ranges") == [[1, 5, 7]]
      else
        sql(first, "UPDATE ranges SET finish=7 WHERE id=1")
      end
    end
  end

  test "another connection's uncommitted conflict row cannot become a protected witness", %{
    first: first,
    second: second
  } do
    for read_uncommitted <- [0, 1] do
      sql(first, "PRAGMA read_uncommitted=#{read_uncommitted}")

      for owner <- [:caller, :adapter] do
        sql(second, "BEGIN")
        sql(second, "INSERT INTO ranges VALUES(3,1,2)")
        if owner == :caller, do: sql(first, "BEGIN DEFERRED")

        assert {:error, %Error{type: :transaction_failed}} =
                 Adapter.execute_prepared_write_unsafe(first, fn loader ->
                   flunk("prepared callback ran beside #{inspect(loader)}")
                 end)

        sql(second, "ROLLBACK")

        if owner == :caller do
          assert Exqlite.Sqlite3.transaction_status(first) == {:ok, :transaction}
          sql(first, "ROLLBACK")
        end

        assert Exqlite.Sqlite3.transaction_status(first) == {:ok, :idle}
        assert rows(first, "SELECT * FROM ranges") == [[1, 5, 7]]
      end
    end
  end

  test "read_uncommitted governing connections receive no protected candidate", %{
    first: first,
    second: second
  } do
    sql(first, "PRAGMA read_uncommitted=1")

    for owner <- [:caller, :adapter] do
      if owner == :caller, do: caller(first)
      before = rows(first, "SELECT * FROM ranges")

      assert_uncommitted_refusal(
        Adapter.execute_prepared_write_unsafe(first, fn loader ->
          with {:ok, final} <- prepare(loader, upsert(%{id: 1, finish: Decimal.new(6)})),
               do: {:ok, final, %{}}
        end)
      )

      assert_uncommitted_refusal(
        Adapter.execute_prepared_write_unsafe(first, fn loader ->
          with {:ok, _state} <- loader.(record_request()), do: {:ok, update(), %{}}
        end)
      )

      assert_uncommitted_refusal(
        Adapter.preview_prepared_write(
          first,
          fn loader ->
            with {:ok, final} <- prepare(loader, upsert(%{id: 1, finish: Decimal.new(6)})),
                 do: {:ok, final, %{}}
          end,
          []
        )
      )

      assert rows(first, "SELECT * FROM ranges") == before
      if owner == :caller, do: assert_caller(first)
    end

    assert rows(second, "SELECT * FROM ranges") == [[1, 5, 7]]
  end

  test "enabling read_uncommitted after projection voids the receipt before DML", %{
    first: first
  } do
    caller(first)
    :ok = Exqlite.Sqlite3.set_update_hook(first, self())

    assert_uncommitted_refusal(
      Adapter.execute_prepared_write_unsafe(first, fn loader ->
        with {:ok, final} <- prepare(loader, upsert(%{id: 1, finish: Decimal.new(6)})) do
          sql(first, "PRAGMA read_uncommitted=1")
          {:ok, final, %{}}
        end
      end)
    )

    refute_received {_action, "main", "ranges", _rowid}
    assert rows(first, "SELECT * FROM ranges") == [[1, 5, 7]]
    sql(first, "PRAGMA read_uncommitted=0")
    assert_caller(first)
  end

  defp assert_uncommitted_refusal(result) do
    assert {:error,
            %Error{
              details: %{code: :required_data_rule_pending, isolation: :read_uncommitted}
            }} = result
  end

  defp caller(db) do
    sql(db, "BEGIN DEFERRED")
    sql(db, "SAVEPOINT original_caller")
  end

  defp assert_caller(db) do
    assert Exqlite.Sqlite3.transaction_status(db) == {:ok, :transaction}
    sql(db, "ROLLBACK TO original_caller")
    sql(db, "RELEASE original_caller")
    sql(db, "ROLLBACK")
    assert Exqlite.Sqlite3.transaction_status(db) == {:ok, :idle}
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
             Map.merge(command.metadata, %{
               protected_upsert_receipt: state.receipt,
               protected_upsert_subject: subject
             })
       }}
    end
  end

  defp upsert(values) do
    {:ok, command} =
      Command.new(%{
        operation: :upsert,
        relation: "ranges",
        assignments:
          Enum.map(values, fn {field, value} -> %{field: field, value: {:literal, value}} end),
        required_capabilities: [:upsert, :protected_upsert_candidates],
        metadata: %{conflict_target: [:id], upsert_update_fields: [:finish], field_types: @types}
      })

    command
  end

  defp update do
    {:ok, command} =
      Command.new(%{
        operation: :update,
        relation: "ranges",
        assignments: [%{field: :finish, value: {:literal, Decimal.new(6)}}],
        predicate: {:eq, {:field, :id}, {:literal, 1}},
        expected_cardinality: {:exactly, 1},
        returning: :none
      })

    command
  end

  defp record_request,
    do: %RecordRequest{
      operation: :update,
      relation: "ranges",
      predicate: {:eq, {:field, :id}, {:literal, 1}},
      fields: ["id", "start", "finish"]
    }

  defp sql(db, query), do: assert({:ok, _} = Adapter.execute(db, query, [], []))

  defp rows(db, query) do
    {:ok, %{rows: rows}} = Adapter.execute(db, query, [], [])
    rows
  end
end
