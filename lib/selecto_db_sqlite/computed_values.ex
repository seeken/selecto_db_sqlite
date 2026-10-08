defmodule SelectoDBSQLite.ComputedValues do
  @moduledoc false
  alias Selecto.Dialect.ComputedValue
  alias SelectoDBSQLite.RuntimeCapabilities

  @casts %{
    "string" => "TEXT",
    "integer" => "INTEGER",
    "decimal" => "NUMERIC",
    "boolean" => "INTEGER",
    "date" => "TEXT",
    "utc_datetime" => "TEXT"
  }

  def render(
        %ComputedValue{operation: :divide, expression: [left, right], type: "decimal", path: []} =
          fragment,
        _selecto
      )
      when map_size(fragment) == 5 do
    if sql?(left) and present?(left) and sql?(right) and present?(right),
      do: {:ok, ["(CAST(", left, " AS REAL) / CAST(", right, " AS REAL))"]},
      else: invalid(:divide)
  end

  def render(
        %ComputedValue{operation: :cast, type: type, path: [], expression: expression} = fragment,
        _selecto
      )
      when map_size(fragment) == 5 do
    with {:ok, target} <- Map.fetch(@casts, type),
         true <- sql?(expression) and present?(expression) do
      {:ok, ["CAST(", expression, " AS ", target, ")"]}
    else
      _ -> invalid(:cast)
    end
  end

  def render(
        %ComputedValue{
          operation: :json_text,
          type: nil,
          path: [_ | _] = path,
          expression: expression
        } = fragment,
        selecto
      )
      when map_size(fragment) == 5 do
    with true <- sql?(expression) and present?(expression),
         true <- Enum.all?(path, &path_marker?/1),
         :ok <- RuntimeCapabilities.require_feature(selecto, :json_text) do
      # Keep each path marker bound and ordered. JSON scalar booleans require
      # their JSON spelling rather than SQLite's extracted integer representation.
      path_sql = ["('$' || ", path |> Enum.map(&path_segment/1) |> Enum.intersperse(" || "), ")"]

      {:ok,
       [
         "(SELECT CASE WHEN json_valid(selecto_computed.doc) THEN CASE json_type(selecto_computed.doc, selecto_computed.path) ",
         "WHEN 'true' THEN 'true' WHEN 'false' THEN 'false' WHEN 'null' THEN NULL ",
         "ELSE CAST(json_extract(selecto_computed.doc, selecto_computed.path) AS TEXT) END END ",
         "FROM (SELECT ",
         expression,
         " AS doc, ",
         path_sql,
         " AS path) AS selecto_computed)"
       ]}
    else
      {:error, _} = error -> error
      _ -> invalid(:json_text)
    end
  end

  def render(_fragment, _selecto), do: invalid(:unknown)

  defp path_marker?({:param, value}) when is_binary(value),
    do: Regex.match?(~r/\A[A-Za-z0-9_]+\z/, value)

  defp path_marker?(_), do: false

  defp path_segment({:param, value} = marker) do
    if Regex.match?(~r/\A[0-9]+\z/, value),
      do: ["('[' || ", marker, " || ']')"],
      else: ["('.\"' || ", marker, " || '\"')"]
  end

  defp sql?(value) when is_binary(value), do: true
  defp sql?(value) when is_integer(value), do: value in 0..255
  defp sql?({:param, _}), do: true
  defp sql?(value) when is_list(value), do: Enum.all?(value, &sql?/1)
  defp sql?(_), do: false
  defp present?(value) when is_binary(value), do: byte_size(value) > 0
  defp present?(value) when is_list(value), do: Enum.any?(value, &present?/1)
  defp present?(_), do: true

  defp invalid(operation),
    do:
      {:error,
       Selecto.Error.validation_error("Invalid SQLite computed-value fragment", %{
         operation: operation,
         unsupported_feature: :computed_value
       })}
end
