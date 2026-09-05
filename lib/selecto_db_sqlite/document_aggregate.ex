defmodule SelectoDBSQLite.DocumentAggregate do
  @moduledoc false
  alias Selecto.Document.{Path, ShapeRelease}
  alias Selecto.Query.{Plan, Result}

  # The materialized candidate CTE is shared by native totals and validation
  # evidence. Validation cannot race a separate read of the same documents.
  def compile(plan, source, params) do
    aggregates = Enum.map_join(plan.aggregates, ", ", &expression(plan, &1))

    sql =
      "WITH candidates AS MATERIALIZED (SELECT document #{source} LIMIT ?), " <>
        "stats AS (SELECT COUNT(*) AS n, " <>
        "COALESCE(SUM(length(CAST(document AS BLOB))), 0) AS bytes FROM candidates) " <>
        "SELECT n, bytes, " <>
        "CASE WHEN n <= ? AND bytes <= ? THEN " <>
        "(SELECT json_group_array(document) FROM candidates) ELSE NULL END, " <>
        "(SELECT json_array(#{aggregates}) FROM candidates) FROM stats"

    params =
      params ++
        [
          plan.bounds["max_input_rows"] + 1,
          plan.bounds["max_input_rows"],
          plan.bounds["max_bytes"]
        ]

    {%{sql: sql, params: params},
     %{
       "operation" => "aggregate",
       "pushdown" => ["tenant", "predicate", "count", "sum", "min", "max"],
       "residual" => ["bounded_shape_and_integer_validation"],
       "parameter_count" => length(params)
     }}
  end

  def normalize([[count, bytes, evidence, output]], compiled) do
    plan = compiled.plan

    with true <- is_integer(count) and count <= plan.bounds["max_input_rows"],
         true <- is_integer(bytes) and bytes <= plan.bounds["max_bytes"],
         true <- is_binary(evidence) and is_binary(output),
         {:ok, documents} <- Jason.decode(evidence),
         true <- is_list(documents) and length(documents) == count,
         true <- Enum.all?(documents, &valid_document?(&1, plan)),
         {:ok, row} <- Jason.decode(output),
         result = %Result{
           columns: Enum.map(plan.projection, & &1["id"]),
           rows: [row],
           next_cursor: nil,
           metadata: compiled.metadata
         },
         :ok <- Result.validate(result, plan) do
      {:ok, result}
    else
      _ -> error()
    end
  end

  def normalize(_rows, _compiled), do: error()

  defp valid_document?(json, plan) when is_binary(json) do
    with {:ok, document} <- Jason.decode(json),
         :ok <- ShapeRelease.validate_document(plan.release, document) do
      Enum.all?(plan.aggregates, fn
        %{"op" => "count"} ->
          true

        aggregate ->
          Plan.aggregate_input?(plan, aggregate, Path.fetch(document, aggregate["field"]["path"]))
      end)
    else
      _ -> false
    end
  end

  defp valid_document?(_, _), do: false

  defp expression(_plan, %{"op" => "count"}), do: "COUNT(*)"

  defp expression(plan, aggregate) do
    path = "$" <> Enum.map_join(aggregate["field"]["path"], "", &(".\"" <> &1 <> "\""))
    value = "json_extract(document, '#{path}')"
    type = "json_type(document, '#{path}')"
    bound = Plan.aggregate_input_limit(plan, aggregate)
    function = %{"sum" => "SUM", "min" => "MIN", "max" => "MAX"}[aggregate["op"]]

    # Prevent SQLite coercion and overflow before local evidence validation.
    "#{function}(CASE WHEN #{type} = 'integer' AND #{value} BETWEEN -#{bound} AND #{bound} " <>
      "THEN #{value} ELSE NULL END)"
  end

  defp error,
    do:
      {:error, Selecto.Error.validation_error("SQLite aggregate input violates shape or bounds")}
end
