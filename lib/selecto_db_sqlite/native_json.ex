defmodule SelectoDBSQLite.NativeJson do
  @moduledoc false

  # Only this bundled, adapter-owned library is loaded automatically. Extension
  # loading is always disabled again, including on an installation failure.
  def install(connection) do
    try do
      if available?(connection), do: :ok, else: install_extension(connection)
    after
      Exqlite.Sqlite3.enable_load_extension(connection, false)
    end
  end

  def available?(connection) do
    sql =
      "SELECT selecto_json_contains_exact_v1('{\"n\":1.0000000000000000001}', '{\"n\":1}') = 0 AND " <>
        "selecto_json_contains_exact_v1('{\"n\":9007199254740993.0}', '{\"n\":9007199254740993}') = 1 AND " <>
        "selecto_json_contains_exact_v1('{\"k\":1,\"k\":2}', '{\"k\":2}') = 1 AND " <>
        "selecto_json_contains_exact_v1('[true]', 'true') = 1 AND " <>
        "selecto_json_contains_exact_v1('[true]', '1') = 0"

    case SelectoDBSQLite.Adapter.execute(connection, sql, [], []) do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  end

  defp install_extension(connection) do
    library = Path.join(to_string(:code.priv_dir(:selecto_db_sqlite)), "selecto_json_contains.so")

    with true <- File.regular?(library),
         :ok <- Exqlite.Sqlite3.enable_load_extension(connection, true) do
      try do
        case SelectoDBSQLite.Adapter.execute(
               connection,
               "SELECT load_extension(?, ?)",
               [library, "sqlite3_selectojson_init"],
               []
             ) do
          {:ok, _} -> if available?(connection), do: :ok, else: unsupported()
          _ -> {:error, :sqlite_exact_json_extension_unavailable}
        end
      after
        Exqlite.Sqlite3.enable_load_extension(connection, false)
      end
    else
      _ -> {:error, :sqlite_exact_json_extension_unavailable}
    end
  end

  defp unsupported, do: {:error, :sqlite_exact_json_extension_unavailable}
end
