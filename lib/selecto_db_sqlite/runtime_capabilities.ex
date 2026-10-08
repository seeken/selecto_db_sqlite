defmodule SelectoDBSQLite.RuntimeCapabilities do
  @moduledoc false
  alias SelectoDBSQLite.Adapter

  def inspect_connection(connection) do
    version = scalar(connection, "SELECT sqlite_version()")

    options =
      case Adapter.execute(connection, "PRAGMA compile_options", [], []) do
        {:ok, %{rows: rows}} -> Enum.map(rows, &hd/1)
        _ -> []
      end

    json = scalar(connection, "SELECT json_valid('[]')") == 1
    fts5 = scalar(connection, "SELECT 1 FROM pragma_module_list WHERE name = 'fts5'") == 1
    math = scalar(connection, "SELECT floor(1.5)") in [1, 1.0]
    cte = version_at_least?(version, {3, 8, 3}) and "OMIT_CTE" not in options
    windows = version_at_least?(version, {3, 28, 0}) and "OMIT_WINDOWFUNC" not in options
    returning = version_at_least?(version, {3, 35, 0}) and "OMIT_RETURNING" not in options

    %{
      server_version: version,
      compile_options: options,
      features: %{
        cte: cte,
        recursive_cte: cte,
        window_functions: windows,
        returning: returning,
        right_join: version_at_least?(version, {3, 39, 0}),
        full_join: version_at_least?(version, {3, 39, 0}),
        ordered_aggregate: version_at_least?(version, {3, 44, 0}),
        calendar_shift: version_at_least?(version, {3, 46, 0}),
        bounded_related_collections: json and version_at_least?(version, {3, 35, 0}),
        schema_introspection: version_at_least?(version, {3, 26, 0}),
        json: json,
        json_rowset: json,
        json_contains: json,
        json_text: json,
        array_rowset: json,
        array_predicates: json,
        text_search: fts5,
        math_functions: math,
        value_expressions: true,
        stream: true,
        set_operations: true,
        transactions: true,
        query_analysis: true
      }
    }
  end

  def version_at_least?(version, minimum) when is_binary(version) do
    case Regex.run(~r/\A(\d+)\.(\d+)\.(\d+)\z/, version, capture: :all_but_first) do
      [major, minor, patch] ->
        {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)} >= minimum

      _ ->
        false
    end
  end

  def version_at_least?(_version, _minimum), do: false

  # Compile-only queries can express the adapter's maximum syntax. Connected
  # renderers require the actual provider feature rather than a coarse flag.
  def require_feature(selecto, feature) do
    connection = Selecto.Runtime.Context.connection(selecto)

    if is_reference(connection) or
         (is_map(connection) and is_reference(Map.get(connection, :connection))) do
      if Adapter.supports?(connection, feature),
        do: :ok,
        else: unsupported(feature)
    else
      :ok
    end
  end

  def unsupported(feature),
    do:
      {:error,
       Selecto.Error.validation_error(
         "SQLite provider does not support the requested feature",
         %{adapter: :sqlite, unsupported_feature: feature}
       )}

  defp scalar(connection, sql) do
    case Adapter.execute(connection, sql, [], []) do
      {:ok, %{rows: [[value] | _]}} -> value
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
