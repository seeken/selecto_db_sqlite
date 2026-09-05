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

  defp element_guard("string") do
    "CASE WHEN item.type = 'text' AND length(CAST(item.value AS BLOB)) <= 16384 " <>
      "THEN (#{valid_utf8()}) ELSE 0 END"
  end

  defp element_guard("integer"),
    do: "item.type = 'integer' AND item.value BETWEEN -9007199254740991 AND 9007199254740991"

  defp element_guard("boolean"), do: "item.type IN ('true', 'false')"

  # SQLite's JSON parser can retain malformed UTF-8. Validate bytes natively
  # before membership, including surrogate, overlong and >U+10FFFF exclusions.
  # Only a position is recursive; BLOB offsets avoid rescanning a TEXT prefix
  # on every step, so work is linear in the bounded byte count.
  defp valid_utf8 do
    ranges = [
      {2, "[0-7][0-9A-F]"},
      {4, "C[2-9A-F][89AB][0-9A-F]"},
      {4, "D[0-9A-F][89AB][0-9A-F]"},
      {6, "E0[AB][0-9A-F][89AB][0-9A-F]"},
      {6, "E[123456789ABCEF][89AB][0-9A-F][89AB][0-9A-F]"},
      {6, "ED[89][0-9A-F][89AB][0-9A-F]"},
      {8, "F0[9AB][0-9A-F][89AB][0-9A-F][89AB][0-9A-F]"},
      {8, "F[123][89AB][0-9A-F][89AB][0-9A-F][89AB][0-9A-F]"},
      {8, "F48[0-9A-F][89AB][0-9A-F][89AB][0-9A-F]"}
    ]

    step =
      Enum.map_join(ranges, " ", fn {width, pattern} ->
        "WHEN CAST(substr(bytes, pos, #{width}) AS TEXT) GLOB '#{pattern}' THEN pos + #{width}"
      end)

    "EXISTS (WITH RECURSIVE " <>
      "encoded(bytes, size) AS MATERIALIZED (SELECT CAST(hex(CAST(item.value AS BLOB)) AS BLOB), " <>
      "2 * length(CAST(item.value AS BLOB))), " <>
      "walk(pos) AS (SELECT 1 UNION ALL SELECT CASE #{step} ELSE 0 END " <>
      "FROM walk, encoded WHERE pos > 0 AND pos <= size) " <>
      "SELECT 1 FROM walk, encoded WHERE pos = size + 1)"
  end
end
