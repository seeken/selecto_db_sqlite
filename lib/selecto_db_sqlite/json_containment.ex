defmodule SelectoDBSQLite.JsonContainment do
  @moduledoc false

  # json_each exposes the JSON type separately from its SQL scalar value.
  # Recursing over that pair preserves null/missing and boolean/number identity,
  # while bound object keys avoid JSONPath escaping restrictions.
  def render(column, needle) do
    {predicate, _next_alias} =
      match_value(["json_extract(", column, ", '$')"], ["json_type(", column, ")"], needle, 0, 0)

    {:ok,
     [
       "CASE WHEN ",
       column,
       " IS NULL THEN NULL WHEN json_valid(",
       column,
       ") THEN (",
       predicate,
       ") ELSE 0 END"
     ]}
  rescue
    error in ArgumentError ->
      {:error,
       Selecto.Error.validation_error(Exception.message(error), %{
         unsupported_feature: :json_contains
       })}
  end

  defp match_value(_value, _type, _needle, _next_alias, depth) when depth > 32,
    do: raise(ArgumentError, "SQLite JSON containment exceeds the maximum nesting depth of 32")

  defp match_value(value, type, needle, next_alias, depth)
       when is_map(needle) and not is_struct(needle) do
    {members, next_alias} =
      needle
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map_reduce(next_alias, fn {key, child}, index ->
        unless is_binary(key) or is_atom(key),
          do: raise(ArgumentError, "JSON object keys must be strings")

        alias_name = "selecto_contains_#{index}"

        {child_match, next} =
          match_value(alias_name <> ".value", alias_name <> ".type", child, index + 1, depth + 1)

        {[
           "EXISTS (SELECT 1 FROM json_each(",
           value,
           ") AS ",
           alias_name,
           " WHERE ",
           alias_name,
           ".key COLLATE BINARY = ",
           {:param, to_string(key)},
           " AND (",
           child_match,
           "))"
         ], next}
      end)

    {["CASE WHEN ", type, " = 'object' THEN (", conjunction(members), ") ELSE 0 END"], next_alias}
  end

  defp match_value(value, type, needle, next_alias, depth) when is_list(needle) do
    {members, next_alias} =
      Enum.map_reduce(needle, next_alias, fn child, index ->
        alias_name = "selecto_contains_#{index}"

        {child_match, next} =
          match_value(alias_name <> ".value", alias_name <> ".type", child, index + 1, depth + 1)

        {[
           "EXISTS (SELECT 1 FROM json_each(",
           value,
           ") AS ",
           alias_name,
           " WHERE (",
           child_match,
           "))"
         ], next}
      end)

    {["CASE WHEN ", type, " = 'array' THEN (", conjunction(members), ") ELSE 0 END"], next_alias}
  end

  defp match_value(_value, type, nil, next_alias, _depth),
    do: {[type, " = 'null'"], next_alias}

  defp match_value(_value, type, true, next_alias, _depth),
    do: {[type, " = 'true'"], next_alias}

  defp match_value(_value, type, false, next_alias, _depth),
    do: {[type, " = 'false'"], next_alias}

  defp match_value(value, type, needle, next_alias, _depth) when is_binary(needle),
    do: {[type, " = 'text' AND ", value, " COLLATE BINARY = ", {:param, needle}], next_alias}

  defp match_value(value, type, needle, next_alias, _depth)
       when is_integer(needle) or is_float(needle),
       do: {[type, " IN ('integer', 'real') AND ", value, " = ", {:param, needle}], next_alias}

  defp match_value(_value, _type, _needle, _next_alias, _depth),
    do: raise(ArgumentError, "SQLite JSON containment requires a JSON value")

  defp conjunction([]), do: "1"
  defp conjunction(members), do: Enum.intersperse(members, " AND ")
end
