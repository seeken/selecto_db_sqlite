defmodule SelectoDBSQLite.ReadErrorSanitizationTest do
  use ExUnit.Case, async: true

  alias SelectoDBSQLite.Adapter

  test "read errors keep a stable category without SQLite text, schema names or SQL" do
    {:ok, conn} = Adapter.connect(database: ":memory:")
    on_exit(fn -> Exqlite.Sqlite3.close(conn) end)

    assert {:ok, _} =
             Adapter.execute(
               conn,
               "CREATE TABLE people (id INTEGER PRIMARY KEY, email VARCHAR NOT NULL UNIQUE)",
               [],
               []
             )

    insert = "INSERT INTO people (id, email) VALUES (?, ?)"
    assert {:ok, _} = Adapter.execute(conn, insert, [1, "secret-value@example.test"], [])

    assert {:error, duplicate} =
             Adapter.execute(conn, insert, [2, "secret-value@example.test"], [])

    assert {:error, missing} = Adapter.execute(conn, insert, [3, nil], [])
    assert {:error, unknown} = Adapter.execute(conn, "SELECT secret_marker FROM people", [], [])

    for {reason, category} <- [
          {duplicate, :unique_violation},
          {missing, :not_null_violation},
          {unknown, :database_error}
        ] do
      error = Adapter.normalize_error(reason)
      rendered = inspect(error, limit: :infinity, printable_limit: :infinity)

      refute rendered =~ "people"
      refute rendered =~ "secret"
      assert %Selecto.Error{type: :query_error, details: %{category: ^category}} = error
    end
  end
end
