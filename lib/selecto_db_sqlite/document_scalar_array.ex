defmodule SelectoDBSQLite.DocumentScalarArray do
  @moduledoc false

  def predicate(%{"op" => op, "field" => field, "value" => requested}, path) do
    descriptor = field["scalar_array"]
    members = if op == "contains", do: [requested], else: requested
    source = "json_each(document, '#{path}')"
    guard = element_guard(descriptor["element_type"])

    membership =
      if op == "contains_all" do
        "NOT EXISTS (SELECT 1 FROM json_each(?) AS wanted WHERE NOT EXISTS " <>
          "(SELECT 1 FROM #{source} AS item WHERE item.value COLLATE BINARY = wanted.value))"
      else
        "EXISTS (SELECT 1 FROM #{source} AS item JOIN json_each(?) AS wanted " <>
          "ON item.value COLLATE BINARY = wanted.value)"
      end

    # CASE avoids enumerating an over-bound array. The complete bounded array
    # must be well typed; matching only a valid prefix would change semantics.
    sql =
      "CASE WHEN json_type(document, '#{path}') = 'array' " <>
        "AND json_array_length(document, '#{path}') <= #{descriptor["max_elements"]} " <>
        "THEN CASE WHEN NOT EXISTS (SELECT 1 FROM #{source} AS item WHERE NOT (#{guard})) " <>
        "THEN (#{membership}) ELSE 0 END ELSE 0 END"

    {sql, [Jason.encode!(members)]}
  end

  defp element_guard("string"),
    do: "item.type = 'text' AND length(CAST(item.value AS BLOB)) <= 16384"

  defp element_guard("integer"),
    do: "item.type = 'integer' AND item.value BETWEEN -9007199254740991 AND 9007199254740991"

  defp element_guard("boolean"), do: "item.type IN ('true', 'false')"
end
