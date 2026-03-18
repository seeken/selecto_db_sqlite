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

  test "sqlite adapter supports nested transactions with savepoints" do
    assert {:ok, conn} = SelectoDBSQLite.Adapter.connect(database: ":memory:")

    assert {:ok, _} =
             SelectoDBSQLite.Adapter.execute(
               conn,
               "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
               [],
               []
             )

    assert {:ok, :outer_ok} =
             SelectoDBSQLite.Adapter.transaction(conn, fn tx_conn ->
               assert {:ok, _} =
                        SelectoDBSQLite.Adapter.execute(
                          tx_conn,
                          "INSERT INTO users (id, name) VALUES (?, ?)",
                          [1, "Outer"],
                          []
                        )

               assert {:error, :inner_rollback} =
                        SelectoDBSQLite.Adapter.transaction(tx_conn, fn inner_conn ->
                          SelectoDBSQLite.Adapter.execute(
                            inner_conn,
                            "INSERT INTO users (id, name) VALUES (?, ?)",
                            [2, "Inner"],
                            []
                          )

                          {:error, :inner_rollback}
                        end)

               :outer_ok
             end)

    assert {:ok, %{rows: [[1]], columns: ["total"]}} =
             SelectoDBSQLite.Adapter.execute(conn, "SELECT COUNT(*) AS total FROM users", [], [])

    assert :ok = Exqlite.Sqlite3.close(conn)
  end

  test "sqlite adapter transaction rolls back on raised exception" do
    assert {:ok, conn} = SelectoDBSQLite.Adapter.connect(database: ":memory:")

    assert {:ok, _} =
             SelectoDBSQLite.Adapter.execute(
               conn,
               "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
               [],
               []
             )

    assert {:error, %RuntimeError{message: "boom"}} =
             SelectoDBSQLite.Adapter.transaction(conn, fn tx_conn ->
               SelectoDBSQLite.Adapter.execute(
                 tx_conn,
                 "INSERT INTO users (id, name) VALUES (?, ?)",
                 [1, "Crash"],
                 []
               )

               raise "boom"
             end)

    assert {:ok, %{rows: [[0]], columns: ["total"]}} =
             SelectoDBSQLite.Adapter.execute(conn, "SELECT COUNT(*) AS total FROM users", [], [])

    assert :ok = Exqlite.Sqlite3.close(conn)
  end

  test "sqlite adapter rejects pid and atom connection options" do
    pid = self()

    assert {:error, {:invalid_connection_options, :named_conn}} =
             SelectoDBSQLite.Adapter.connect(:named_conn)

    assert {:error, {:invalid_connection_options, ^pid}} =
             SelectoDBSQLite.Adapter.connect(pid)
  end

  test "sqlite adapter reports disconnected info for closed connection" do
    assert {:ok, conn} = SelectoDBSQLite.Adapter.connect(database: ":memory:")
    assert :ok = Exqlite.Sqlite3.close(conn)

    assert {:error, {:connection_unhealthy, _reason}} =
             SelectoDBSQLite.Adapter.validate_connection(conn)

    assert %{type: :sqlite, connection: :exqlite, status: :disconnected, reason: _reason} =
             SelectoDBSQLite.Adapter.connection_info(conn)
  end

  test "sqlite adapter rejects invalid connection values" do
    assert SelectoDBSQLite.Adapter.execute(:invalid, "SELECT 1", [], []) ==
             {:error, {:invalid_connection, :invalid}}
  end

  test "sqlite adapter does not claim stream support" do
    refute SelectoDBSQLite.Adapter.supports?(:stream)
  end

  test "sqlite adapter reports schema introspection support" do
    assert SelectoDBSQLite.Adapter.supports?(:schema_introspection)
  end

  test "sqlite adapter lists tables for selecto_mix generators" do
    assert {:ok, conn} = SelectoDBSQLite.Adapter.connect(database: ":memory:")

    assert {:ok, _} =
             SelectoDBSQLite.Adapter.execute(
               conn,
               "CREATE TABLE accounts (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
               [],
               []
             )

    assert {:ok, _} =
             SelectoDBSQLite.Adapter.execute(
               conn,
               "CREATE TABLE orders (id INTEGER PRIMARY KEY, account_id INTEGER REFERENCES accounts(id))",
               [],
               []
             )

    assert {:ok, ["accounts", "orders"]} = SelectoDBSQLite.Adapter.list_tables(conn)
    assert :ok = Exqlite.Sqlite3.close(conn)
  end

  test "sqlite adapter introspects tables for selecto_mix generators" do
    assert {:ok, conn} = SelectoDBSQLite.Adapter.connect(database: ":memory:")
    assert {:ok, _} = SelectoDBSQLite.Adapter.execute(conn, "PRAGMA foreign_keys = ON", [], [])

    assert {:ok, _} =
             SelectoDBSQLite.Adapter.execute(
               conn,
               "CREATE TABLE accounts (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
               [],
               []
             )

    assert {:ok, _} =
             SelectoDBSQLite.Adapter.execute(
               conn,
               "CREATE TABLE orders (id INTEGER PRIMARY KEY, account_id INTEGER NOT NULL REFERENCES accounts(id), inserted_at TEXT)",
               [],
               []
             )

    assert {:ok, metadata} =
             SelectoDBSQLite.Adapter.introspect_table(conn, "orders", expand: false)

    assert metadata.table_name == "orders"
    assert metadata.schema == "main"
    assert metadata.fields == [:id, :account_id, :inserted_at]
    assert metadata.field_types.id == :integer
    assert metadata.field_types.inserted_at == :string
    assert metadata.primary_key == :id
    assert metadata.source == :sqlite

    assert metadata.associations == %{
             account: %{
               association_type: :belongs_to,
               constraint_name: "fk_orders_0",
               field: :account,
               is_through: false,
               join_type: :inner,
               owner_key: :account_id,
               queryable: :accounts,
               related_key: :id,
               related_module_name: "Account",
               related_schema: "Account",
               related_table: "accounts",
               type: :belongs_to
             }
           }

    assert :ok = Exqlite.Sqlite3.close(conn)
  end
end
