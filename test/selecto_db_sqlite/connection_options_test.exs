defmodule SelectoDBSQLite.ConnectionOptionsTest do
  use ExUnit.Case, async: false

  alias SelectoDBSQLite.Adapter

  test "declared Exqlite range admits the supported explicit open flags" do
    {:exqlite, requirement} = List.keyfind(Mix.Project.config()[:deps], :exqlite, 0)

    refute Version.match?("0.35.0", requirement)
    refute Version.match?("0.37.0", requirement)
    assert Version.match?("0.39.0", requirement)
    assert Version.match?(to_string(Application.spec(:exqlite, :vsn)), requirement)

    assert {:ok, connection} =
             Adapter.connect(database: ":memory:", temp_store: :memory)

    on_exit(fn -> Adapter.disconnect(connection) end)

    assert {:ok, %{rows: [[2]]}} = Adapter.execute(connection, "PRAGMA temp_store", [], [])
    assert {:ok, %{rows: rows}} = Adapter.execute(connection, "PRAGMA database_list", [], [])
    assert Enum.all?(rows, fn [_sequence, _name, file] -> file == "" end)
  end

  test "applies documented settings to an in-memory database" do
    assert {:ok, connection} =
             Adapter.connect(%{
               database: ":memory:",
               journal_mode: :memory,
               cache_size: -777,
               synchronous: :off,
               temp_store: :memory,
               busy_timeout: 1234,
               foreign_keys: :off
             })

    on_exit(fn -> Adapter.disconnect(connection) end)

    for {key, expected} <- [
          journal_mode: "memory",
          cache_size: -777,
          synchronous: 0,
          temp_store: 2,
          busy_timeout: 1234,
          foreign_keys: 0
        ] do
      assert {:ok, %{rows: [[^expected]]}} = Adapter.execute(connection, "PRAGMA #{key}", [], [])
    end
  end

  test "SQLite retains its supported journal mode for memory databases requesting WAL" do
    assert {:ok, connection} =
             Adapter.connect(database: ":memory:", temp_store: :memory, journal_mode: :wal)

    on_exit(fn -> Adapter.disconnect(connection) end)

    assert {:ok, %{rows: [["memory"]]}} =
             Adapter.execute(connection, "PRAGMA journal_mode", [], [])

    assert {:ok, %{rows: [[1]]}} = Adapter.execute(connection, "PRAGMA foreign_keys", [], [])
  end

  test "validates options before opening a database or executing pragma text" do
    for {key, value} <- [
          journal_mode: "WAL; DELETE FROM secret",
          foreign_keys: :invalid,
          cache_size: "1",
          synchronous: :invalid,
          temp_store: :invalid,
          database: nil,
          mode: [:readonly, :create],
          extensions: [nil],
          typo: true
        ] do
      assert {:error, {:invalid_connection_option, ^key, ^value}} =
               Adapter.connect([{key, value}, {:database, ":memory:"}])
    end

    assert {:error, {:invalid_busy_timeout, -1}} =
             Adapter.connect(database: ":memory:", busy_timeout: -1)

    assert {:error, {:invalid_connection_options, ["invalid"]}} = Adapter.connect(["invalid"])

    assert {:error, {:sqlite_extension_not_found, _}} =
             Adapter.connect(
               database: ":memory:",
               extensions: [Path.join(__DIR__, "nonexistent-extension.so")]
             )
  end

  test "attempts configured extensions and reports loading failure" do
    # Existing source text is deliberately not a native library; no database
    # file is created to prove that extension loading actually occurs.
    assert {:error, {:sqlite_extension_load_failed, _, _}} =
             Adapter.connect(database: ":memory:", extensions: [__ENV__.file])
  end

  test "passes through caller-owned connections without resetting options" do
    assert {:ok, connection} =
             Adapter.connect(database: ":memory:", temp_store: :memory, foreign_keys: :off)

    on_exit(fn -> Adapter.disconnect(connection) end)
    assert Adapter.connect(connection) == {:ok, connection}
    assert {:ok, %{rows: [[0]]}} = Adapter.execute(connection, "PRAGMA foreign_keys", [], [])
  end
end
