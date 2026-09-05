defmodule SelectoDBSQLite.DocumentObjectRelation do
  @moduledoc false
  alias Selecto.Document.{Path, ShapeRelease}
  alias Selecto.Query.Result

  # The native predicate flag and full parent evidence come from one bounded,
  # materialized input. Predicates cannot hide invalid parents or duplicates.
  def compile(plan, source, params, {predicate, predicate_params}, object_type) do
    sql =
      "WITH parents AS MATERIALIZED (SELECT document #{source} LIMIT 2) " <>
        "SELECT CASE WHEN length(CAST(document AS BLOB)) <= ? THEN document ELSE NULL END, " <>
        "CASE WHEN length(CAST(document AS BLOB)) <= ? AND #{object_type} = 'object' " <>
        "THEN CASE WHEN (#{predicate}) THEN 1 ELSE 0 END ELSE 0 END FROM parents"

    params = params ++ [plan.bounds["max_bytes"], plan.bounds["max_bytes"]] ++ predicate_params

    {%{sql: sql, params: params},
     %{
       "operation" => "object_relation",
       "pushdown" => ["tenant", "parent_identity", "predicate", "zero_or_one"],
       "residual" => ["whole_parent_shape_validation", "projection_normalization"],
       "parameter_count" => length(params)
     }}
  end

  def normalize([], compiled), do: result([], compiled)

  def normalize([[json, matched]], compiled) when is_binary(json) and matched in [0, 1] do
    plan = compiled.plan

    with {:ok, document} <- Jason.decode(json),
         {:ok, objects} <- ShapeRelease.object_rows(plan.release, plan.relation["id"], document) do
      case {matched, objects} do
        {1, [object]} ->
          result([Enum.map(plan.projection, &Path.fetch(object, &1["path"]))], compiled)

        {0, _} ->
          result([], compiled)

        _ ->
          error()
      end
    else
      _ -> error()
    end
  end

  def normalize(_, _), do: error()

  defp result(rows, compiled) do
    result = %Result{
      columns: Enum.map(compiled.plan.projection, & &1["id"]),
      rows: rows,
      next_cursor: nil,
      metadata:
        Map.put(
          compiled.metadata,
          "relation_identity",
          Result.relation_identity_metadata(compiled.plan)
        )
    }

    with :ok <- Result.validate(result, compiled.plan), do: {:ok, result}
  end

  defp error,
    do:
      {:error,
       Selecto.Error.validation_error(
         "SQLite object parent violates shape, cardinality, or bounds"
       )}
end
