defmodule SelectoDBSQLite.AdapterTest do
  use ExUnit.Case, async: true

  test "adapter exposes the selecto adapter contract" do
    assert Code.ensure_loaded?(SelectoDBSQLite.Adapter)
    assert function_exported?(SelectoDBSQLite.Adapter, :name, 0)
    assert function_exported?(SelectoDBSQLite.Adapter, :connect, 1)
    assert function_exported?(SelectoDBSQLite.Adapter, :execute, 4)
    assert function_exported?(SelectoDBSQLite.Adapter, :placeholder, 1)
    assert function_exported?(SelectoDBSQLite.Adapter, :quote_identifier, 1)
    assert function_exported?(SelectoDBSQLite.Adapter, :supports?, 1)
    assert function_exported?(SelectoDBSQLite.Adapter, :execute_raw, 3)
    assert function_exported?(SelectoDBSQLite.Adapter, :validate_connection, 1)
    assert function_exported?(SelectoDBSQLite.Adapter, :connection_info, 1)
    assert function_exported?(SelectoDBSQLite.Adapter, :transaction, 3)
  end

  test "sqlite adapter reports expected placeholder and quoting strategy" do
    assert SelectoDBSQLite.Adapter.placeholder(3) == "?"
    assert SelectoDBSQLite.Adapter.quote_identifier("order") == "\"order\""
  end

  test "sqlite adapter executes a simple query" do
    assert {:ok, conn} = SelectoDBSQLite.Adapter.connect(database: ":memory:")

    assert {:ok, %{rows: [[1]], columns: ["value"]}} =
             SelectoDBSQLite.Adapter.execute(conn, "SELECT 1 AS value", [], [])

    assert :ok = Exqlite.Sqlite3.close(conn)
  end

  test "sqlite adapter exposes execute_raw and connection helpers" do
    assert {:ok, conn} = SelectoDBSQLite.Adapter.connect(database: ":memory:")

    assert :ok = SelectoDBSQLite.Adapter.validate_connection(conn)

    assert %{type: :sqlite, connection: :exqlite, status: :connected} =
             SelectoDBSQLite.Adapter.connection_info(conn)

    assert {:ok, %{rows: [[1]], columns: ["value"]}} =
             SelectoDBSQLite.Adapter.execute_raw(conn, "SELECT 1 AS value", [])

    assert :ok = Exqlite.Sqlite3.close(conn)
  end

  test "sqlite adapter transaction commits and rolls back" do
    assert {:ok, conn} = SelectoDBSQLite.Adapter.connect(database: ":memory:")

    assert {:ok, _} =
             SelectoDBSQLite.Adapter.execute(
               conn,
               "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
               [],
               []
             )

    assert {:ok, :inserted} =
             SelectoDBSQLite.Adapter.transaction(conn, fn tx_conn ->
               SelectoDBSQLite.Adapter.execute(
                 tx_conn,
                 "INSERT INTO users (id, name) VALUES (?, ?)",
                 [1, "Ada"],
                 []
               )

               :inserted
             end)

    assert {:error, :force_rollback} =
             SelectoDBSQLite.Adapter.transaction(conn, fn tx_conn ->
               SelectoDBSQLite.Adapter.execute(
                 tx_conn,
                 "INSERT INTO users (id, name) VALUES (?, ?)",
                 [2, "Grace"],
                 []
               )

               {:error, :force_rollback}
             end)

    assert {:ok, %{rows: [[1]], columns: ["total"]}} =
             SelectoDBSQLite.Adapter.execute(conn, "SELECT COUNT(*) AS total FROM users", [], [])

    assert :ok = Exqlite.Sqlite3.close(conn)
  end

  test "sqlite adapter rejects invalid connection values" do
    assert SelectoDBSQLite.Adapter.execute(:invalid, "SELECT 1", [], []) ==
             {:error, {:invalid_connection, :invalid}}
  end

  test "sqlite adapter does not claim stream support" do
    refute SelectoDBSQLite.Adapter.supports?(:stream)
  end
end
