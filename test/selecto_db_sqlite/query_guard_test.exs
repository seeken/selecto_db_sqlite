defmodule SelectoDBSQLite.QueryGuardTest do
  use ExUnit.Case, async: false
  alias SelectoDBSQLite.{Adapter, QueryGuard}

  setup do
    {:ok, conn} = Adapter.connect(database: ":memory:", temp_store: :memory)
    {:ok, _} = Adapter.execute(conn, "CREATE TABLE rows_table (value INTEGER)", [], [])
    {:ok, _} = Adapter.execute(conn, "INSERT INTO rows_table VALUES (1), (2)", [], [])
    on_exit(fn -> Adapter.disconnect(conn) end)
    %{conn: conn}
  end

  test "governed read ports enforce read-only mode and restore the caller's setting", %{
    conn: conn
  } do
    for prior <- [0, 1] do
      {:ok, _} = Adapter.execute(conn, "PRAGMA query_only = #{prior}", [], [])

      assert {:ok, %{rows: [[1]]}} =
               Adapter.execute_query(conn, "SELECT query_only FROM pragma_query_only", [], [])

      assert setting(conn) == prior

      assert {:error, _} =
               Adapter.execute_query(
                 conn,
                 "UPDATE rows_table SET value = 9 RETURNING value",
                 [],
                 []
               )

      assert setting(conn) == prior

      assert {:error, _} =
               Adapter.execute_query(conn, "SELECT absent_column FROM rows_table", [], [])

      assert setting(conn) == prior
    end

    {:ok, _} = Adapter.execute(conn, "PRAGMA query_only = OFF", [], [])
    assert {:ok, _} = Adapter.execute(conn, "INSERT INTO rows_table VALUES (3)", [], [])

    assert {:ok, %{rows: [[1], [2], [3]]}} =
             Adapter.execute(conn, "SELECT value FROM rows_table", [], [])
  end

  test "engine queries route through the guarded adapter callback", %{conn: conn} do
    query =
      Selecto.configure(
        %{
          name: "query_only",
          source: %{
            source_table: "pragma_query_only",
            primary_key: :query_only,
            fields: [:query_only],
            columns: %{query_only: %{type: :integer}},
            associations: %{}
          },
          schemas: %{},
          joins: %{}
        },
        conn,
        adapter: Adapter
      )
      |> Selecto.select(["query_only"])

    assert {:ok, {[[1]], _, _}} = Selecto.execute(query)
    assert setting(conn) == 0
  end

  test "streams own the read guard only while consumed and restore after halt/error", %{
    conn: conn
  } do
    for prior <- [0, 1] do
      {:ok, _} = Adapter.execute(conn, "PRAGMA query_only = #{prior}", [], [])

      assert {:ok, stream, ["query_only"]} =
               Adapter.stream(conn, "SELECT query_only FROM pragma_query_only", [], [])

      assert setting(conn) == prior
      assert Enum.take(stream, 1) == [[1]]
      assert setting(conn) == prior
      assert Enum.to_list(stream) == [[1]]
      assert setting(conn) == prior
      assert {:ok, broken, _} = Adapter.stream(conn, "SELECT json_extract('bad', '$.a')", [], [])
      assert_raise RuntimeError, fn -> Enum.to_list(broken) end
      assert setting(conn) == prior
    end

    {:ok, _} = Adapter.execute(conn, "PRAGMA query_only = OFF", [], [])

    assert {:ok, timed, _} =
             Adapter.stream(
               conn,
               "WITH RECURSIVE n(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM n WHERE value < 10000000) SELECT sum(value) FROM n",
               [],
               stream_timeout: 0
             )

    assert_raise RuntimeError, "SQLite stream timed out", fn -> Enum.to_list(timed) end
    assert setting(conn) == 0
  end

  test "lazy stream preparation and consumer failures release guard ownership", %{conn: conn} do
    {:ok, stream, _} = Adapter.stream(conn, "SELECT value FROM rows_table", [], [])
    {:ok, _} = Adapter.execute(conn, "DROP TABLE rows_table", [], [])
    assert_raise RuntimeError, fn -> Enum.to_list(stream) end
    assert setting(conn) == 0
    {:ok, stream, _} = Adapter.stream(conn, "SELECT 1", [], [])

    assert_raise RuntimeError, "consumer failure", fn ->
      Enum.map(stream, fn _ -> raise "consumer failure" end)
    end

    assert setting(conn) == 0
  end

  test "nested governed operations retain outer ownership", %{conn: conn} do
    assert QueryGuard.run(conn, fn ->
             assert setting(conn) == 1
             assert {:ok, %{rows: [[1]]}} = Adapter.execute_query(conn, "SELECT 1", [], [])
             assert setting(conn) == 1
             :done
           end) == :done

    assert setting(conn) == 0

    assert_raise RuntimeError, "consumer failure", fn ->
      QueryGuard.run(conn, fn -> raise "consumer failure" end)
    end

    assert setting(conn) == 0
  end

  test "concurrent guarded readers cannot disable a live stream or change caller state", %{
    conn: conn
  } do
    test_pid = self()

    first =
      Task.async(fn ->
        {:ok, stream, _} = Adapter.stream(conn, "SELECT value FROM rows_table", [], [])

        Enum.reduce_while(stream, :done, fn row, _ ->
          send(test_pid, {:stream_holds_guard, self(), row})

          receive do
            :finish_stream -> {:halt, :done}
          end
        end)
      end)

    assert_receive {:stream_holds_guard, first_pid, [1]}
    assert setting(conn) == 1

    second =
      Task.async(fn ->
        send(test_pid, :second_started)
        result = Adapter.execute_query(conn, "SELECT query_only FROM pragma_query_only", [], [])
        send(test_pid, :second_finished)
        result
      end)

    assert_receive :second_started
    refute_receive :second_finished, 100
    assert setting(conn) == 1
    send(first_pid, :finish_stream)
    assert Task.await(first) == :done

    assert {:ok, %{columns: ["query_only"], rows: [[1]], num_rows: 1}} =
             Task.await(second, 10_000)

    assert setting(conn) == 0
  end

  test "terminated stream consumers restore state before another reader takes ownership", %{
    conn: conn
  } do
    test_pid = self()

    for prior <- [0, 1] do
      {:ok, _} = Adapter.execute(conn, "PRAGMA query_only = #{prior}", [], [])

      consumer =
        spawn(fn ->
          {:ok, stream, _} = Adapter.stream(conn, "SELECT value FROM rows_table", [], [])

          Enum.each(stream, fn _ ->
            send(test_pid, {:consumer_waiting, self()})

            receive do
              :continue -> :ok
            end
          end)
        end)

      assert_receive {:consumer_waiting, ^consumer}
      assert setting(conn) == 1
      Process.exit(consumer, :kill)
      # Acquisition is queued behind the monitored owner; the coordinator must
      # restore its state before this operation acquires and saves caller state.
      assert {:ok, %{rows: [[1]]}} =
               Adapter.execute_query(conn, "SELECT query_only FROM pragma_query_only", [], [])

      assert setting(conn) == prior
    end
  end

  defp setting(conn) do
    {:ok, %{rows: [[value]]}} = Adapter.execute(conn, "PRAGMA query_only", [], [])
    value
  end
end
