defmodule SelectoDBSQLite.JsonContainment do
  @moduledoc false

  @max_bytes 1_048_576
  @max_nodes 32_768

  # Bind one canonical JSON document; the native comparator retains source
  # numeric tokens instead of passing them through SQLite REAL values.
  def render(column, needle) do
    {value, _budget} = validate(needle, 0, {0, 0})
    encoded = Jason.encode!(value)

    if byte_size(encoded) > @max_bytes,
      do:
        raise(
          ArgumentError,
          "SQLite JSON containment exceeds the maximum input size of 1048576 bytes"
        )

    {:ok, ["selecto_json_contains_exact_v1(", column, ", ", {:param, encoded}, ")"]}
  rescue
    error in [ArgumentError, Jason.EncodeError] ->
      {:error,
       Selecto.Error.validation_error(Exception.message(error), %{
         unsupported_feature: :json_contains
       })}
  end

  defp validate(_value, depth, _nodes) when depth > 32,
    do: raise(ArgumentError, "SQLite JSON containment exceeds the maximum nesting depth of 32")

  defp validate(_value, _depth, {nodes, _bytes}) when nodes >= @max_nodes,
    do: raise(ArgumentError, "SQLite JSON containment exceeds the maximum node count of 32768")

  defp validate(value, depth, budget) when is_map(value) and not is_struct(value) do
    Enum.reduce(value, {%{}, spend(budget, 2, 1)}, fn {key, child}, {object, current} ->
      unless is_binary(key) or is_atom(key),
        do: raise(ArgumentError, "JSON object keys must be strings or atoms")

      key = to_string(key)

      if byte_size(key) > @max_bytes,
        do:
          raise(
            ArgumentError,
            "SQLite JSON containment exceeds the maximum input size of 1048576 bytes"
          )

      unless String.valid?(key), do: raise(ArgumentError, "JSON object keys must be valid UTF-8")

      if Map.has_key?(object, key),
        do: raise(ArgumentError, "JSON object keys must remain unique after string conversion")

      separator = if map_size(object) == 0, do: 1, else: 2
      current = spend(current, byte_size(Jason.encode!(key)) + separator, 0)
      {child, next} = validate(child, depth + 1, current)
      {Map.put(object, key, child), next}
    end)
  end

  defp validate(value, depth, budget) when is_list(value),
    do: validate_list(value, depth, spend(budget, 2, 1), [])

  defp validate(value, _depth, budget) when is_binary(value) do
    if byte_size(value) > @max_bytes,
      do:
        raise(
          ArgumentError,
          "SQLite JSON containment exceeds the maximum input size of 1048576 bytes"
        )

    unless String.valid?(value), do: raise(ArgumentError, "JSON strings must be valid UTF-8")
    {value, spend(budget, byte_size(Jason.encode!(value)), 1)}
  end

  defp validate(value, _depth, budget)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value) do
    if is_integer(value) and :erlang.external_size(value) > @max_bytes,
      do:
        raise(
          ArgumentError,
          "SQLite JSON containment exceeds the maximum input size of 1048576 bytes"
        )

    {value, spend(budget, byte_size(Jason.encode!(value)), 1)}
  end

  defp validate(_value, _depth, _nodes),
    do: raise(ArgumentError, "SQLite JSON containment requires a plain JSON value")

  defp validate_list([], _depth, nodes, values), do: {Enum.reverse(values), nodes}

  defp validate_list([value | tail], depth, nodes, values) do
    nodes = if values == [], do: nodes, else: spend(nodes, 1, 0)
    {value, next} = validate(value, depth + 1, nodes)
    validate_list(tail, depth, next, [value | values])
  end

  defp validate_list(_improper, _depth, _nodes, _values),
    do: raise(ArgumentError, "SQLite JSON containment requires a proper JSON array")

  # Account for the encoded document before encoding it as a whole. Repeated
  # individually valid strings cannot force an unbounded aggregate allocation.
  defp spend({nodes, bytes}, additional_bytes, additional_nodes) do
    if bytes + additional_bytes > @max_bytes,
      do:
        raise(
          ArgumentError,
          "SQLite JSON containment exceeds the maximum input size of 1048576 bytes"
        )

    {nodes + additional_nodes, bytes + additional_bytes}
  end
end
