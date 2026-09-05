defmodule SelectoDBSQLite.DocumentQueryAdapter do
  @moduledoc """
  SQL control for the portable document query plan using a SQLite JSON `document`
  column. The host creates the table and declared expression index explicitly.
  This additive adapter leaves existing Selecto SQL APIs unchanged. V1 supports
  root/nested projections; array relations fail capability preflight.
  """
  @behaviour Selecto.DB.QueryAdapter
  alias Selecto.Document.{Path, ShapeRelease}
  alias Selecto.Query.{CapabilityProfile, Compiled, Cursor, Plan, Result}
  alias SelectoDBSQLite.{Adapter, DocumentAggregate}

  @caps ~w(document.root document.nested query.ordering query.cursor query.limit
           query.aggregate.count query.aggregate.sum query.aggregate.min query.aggregate.max
           predicate.eq predicate.ne predicate.gt predicate.gte predicate.lt predicate.lte
           predicate.in predicate.exists predicate.missing predicate.is_null predicate.is_not_null
           predicate.and predicate.or)

  @impl true
  def contract_version, do: 1

  @impl true
  def capabilities(connection, _context) do
    with {:ok, %{rows: [[version]]}} <-
           Adapter.execute(connection, "SELECT sqlite_version()", [], []) do
      {:ok,
       %CapabilityProfile{
         backend: :sqlite_json,
         version: version,
         deployment: %{"mode" => "embedded"},
         enabled: @caps,
         certified: @caps,
         limits: %{
           "max_rows" => 1000,
           "max_input_rows" => 10_000,
           "max_bytes" => 16_777_216,
           "timeout_ms" => 30_000,
           "max_predicates" => 128
         },
         metadata: %{"proof_scope" => "synthetic-root-json-control"}
       }}
    else
      _ -> error("SQLite source is unavailable")
    end
  end

  @impl true
  def compile_query(_connection, plan, opts) do
    with :ok <- Plan.validate(plan, opts),
         true <- plan.relation["kind"] == "root",
         table when is_binary(table) <- plan.source["sql_table"],
         true <- Path.safe_key?(table),
         index when is_binary(index) <- plan.metadata["access_pattern"]["index"],
         true <- Path.safe_key?(index) do
      {where, params} = predicate(plan.predicates)

      source =
        "FROM #{quote_id(table)} INDEXED BY #{quote_id(index)} " <>
          "WHERE #{json_type(plan.source["tenant_path"])} = 'text' AND " <>
          "#{extract(plan.source["tenant_path"])} = ? AND (#{where})"

      {artifact, metadata} = compile_artifact(plan, source, [plan.tenant | params])

      {:ok,
       %Compiled{
         backend: :sqlite_json,
         plan: plan,
         artifact: artifact,
         metadata: Map.merge(metadata, %{"index" => index, "bounds" => plan.bounds})
       }}
    else
      _ -> error("Unsupported SQLite document query contract")
    end
  end

  defp compile_artifact(%{aggregates: [_ | _]} = plan, source, params),
    do: DocumentAggregate.compile(plan, source, params)

  defp compile_artifact(plan, source, params) do
    {after_sql, after_params} = after_predicate(plan)

    order =
      Enum.map_join(plan.ordering, ", ", fn entry ->
        extract(entry["field"]["path"]) <>
          if(entry["direction"] == "desc", do: " DESC", else: " ASC")
      end)

    sql =
      "SELECT document #{source} AND (#{after_sql}) ORDER BY #{order} LIMIT ?"

    {
      %{
        sql: sql,
        params: params ++ after_params ++ [plan.page["limit"] + 1]
      },
      %{
        "operation" => "select",
        "residual" => ["shape_validation", "projection_normalization"],
        "parameter_count" => 1 + length(params) + length(after_params)
      }
    }
  end

  @impl true
  def preview_query(_connection, compiled, _opts), do: {:ok, compiled.metadata}

  @impl true
  def explain_query(connection, compiled, opts) do
    with {:ok, canonical} <- compile_query(connection, compiled.plan, opts),
         true <- canonical == compiled,
         {:ok, %{rows: rows}} <-
           Adapter.execute(
             connection,
             "EXPLAIN QUERY PLAN " <> compiled.artifact.sql,
             compiled.artifact.params,
             []
           ) do
      details = Enum.map(rows, &List.last/1)

      {:ok,
       %{
         "indexed_search" => Enum.any?(details, &String.starts_with?(&1, "SEARCH ")),
         "unindexed_sort" => Enum.any?(details, &String.contains?(&1, "USE TEMP B-TREE"))
       }}
    else
      _ -> error("SQLite access pattern could not be verified")
    end
  end

  @impl true
  def execute_query(connection, %Compiled{backend: :sqlite_json} = compiled, opts) do
    with :ok <- Plan.validate(compiled.plan, opts),
         {:ok, canonical} <- compile_query(connection, compiled.plan, opts),
         true <- canonical == compiled,
         {:ok, %{"indexed_search" => true, "unindexed_sort" => false}} <-
           explain_query(connection, compiled, opts),
         {:ok, %{rows: rows}} <-
           Adapter.execute(connection, compiled.artifact.sql, compiled.artifact.params,
             timeout: compiled.plan.bounds["timeout_ms"]
           ),
         true <- :erlang.external_size(rows) <= compiled.plan.bounds["max_bytes"],
         {:ok, result} <- normalize(rows, compiled, opts) do
      {:ok, result}
    else
      {:error, %Selecto.Error{} = failure} -> {:error, failure}
      _ -> error("SQLite document query failed validation, execution, or resource bounds")
    end
  end

  defp normalize(rows, %{plan: %{aggregates: [_ | _]}} = compiled, _opts),
    do: DocumentAggregate.normalize(rows, compiled)

  defp normalize(rows, compiled, opts) do
    with {:ok, documents} <- decode(rows, compiled.plan.release),
         {:ok, cursor} <- next_cursor(documents, compiled.plan, opts) do
      selected = Enum.take(documents, compiled.plan.page["limit"])

      {:ok,
       %Result{
         columns: Enum.map(compiled.plan.projection, & &1["id"]),
         rows:
           Enum.map(selected, fn document ->
             Enum.map(compiled.plan.projection, &Path.fetch(document, &1["path"]))
           end),
         next_cursor: cursor,
         metadata: compiled.metadata
       }}
    end
  end

  defp decode(rows, release) do
    Enum.reduce_while(rows, {:ok, []}, fn [json], {:ok, acc} ->
      with {:ok, doc} <- Jason.decode(json),
           :ok <- ShapeRelease.validate_document(release, doc) do
        {:cont, {:ok, [doc | acc]}}
      else
        _ -> {:halt, error("Document violates approved ShapeRelease")}
      end
    end)
    |> case do
      {:ok, docs} -> {:ok, Enum.reverse(docs)}
      other -> other
    end
  end

  defp next_cursor(documents, plan, opts) do
    if length(documents) > plan.page["limit"] do
      last = Enum.at(documents, plan.page["limit"] - 1)
      values = Enum.map(plan.ordering, &Path.fetch(last, &1["field"]["path"]))
      Cursor.encode(plan, values, opts)
    else
      {:ok, nil}
    end
  end

  defp predicate(nil), do: {"1", []}

  defp predicate(%{"op" => op, "args" => args}) when op in ["and", "or"] do
    compiled = Enum.map(args, &predicate/1)

    sql =
      Enum.map_join(compiled, if(op == "and", do: " AND ", else: " OR "), fn {sql, _} ->
        "(" <> sql <> ")"
      end)

    {sql, Enum.flat_map(compiled, &elem(&1, 1))}
  end

  defp predicate(%{"op" => op, "field" => field} = intent) do
    value = extract(field["path"])
    type = json_type(field["path"])
    comparison(op, intent["value"], value, type, field["type"])
  end

  defp comparison("exists", _, _, type, _), do: {"#{type} IS NOT NULL", []}
  defp comparison("missing", _, _, type, _), do: {"#{type} IS NULL", []}
  defp comparison("is_null", _, _, type, _), do: {"#{type} = 'null'", []}

  defp comparison("is_not_null", _, _, type, _),
    do: {"#{type} IS NOT NULL AND #{type} <> 'null'", []}

  defp comparison("in", [], _, _, _), do: {"0", []}

  defp comparison("in", values, expression, type, family) do
    placeholders = Enum.map_join(values, ",", fn _ -> "?" end)

    {guard_type(type, family) <> " AND #{expression} IN (#{placeholders})",
     Enum.map(values, &bind_value/1)}
  end

  defp comparison(op, value, expression, type, family) do
    operator =
      %{"eq" => "=", "ne" => "<>", "gt" => ">", "gte" => ">=", "lt" => "<", "lte" => "<="}[op]

    {guard_type(type, family) <> " AND #{expression} #{operator} ?", [bind_value(value)]}
  end

  defp guard_type(type, "string"), do: "#{type} = 'text'"
  defp guard_type(type, "integer"), do: "#{type} = 'integer'"
  defp guard_type(type, "float"), do: "#{type} = 'real'"
  defp guard_type(type, "boolean"), do: "#{type} IN ('true','false')"

  defp after_predicate(%{page: %{"after" => nil}}), do: {"1", []}

  defp after_predicate(plan) do
    terms = Enum.zip(plan.ordering, plan.page["after"])

    compiled =
      terms
      |> Enum.with_index()
      |> Enum.map(fn {{order, value}, i} ->
        prefix =
          terms
          |> Enum.take(i)
          |> Enum.map(fn {previous, previous_value} ->
            {extract(previous["field"]["path"]) <> " = ?", bind_value(previous_value)}
          end)

        operator = if order["direction"] == "desc", do: " < ?", else: " > ?"
        sql = Enum.map(prefix, &elem(&1, 0)) ++ [extract(order["field"]["path"]) <> operator]

        {"(" <> Enum.join(sql, " AND ") <> ")",
         Enum.map(prefix, &elem(&1, 1)) ++ [bind_value(value)]}
      end)

    {Enum.map_join(compiled, " OR ", &elem(&1, 0)), Enum.flat_map(compiled, &elem(&1, 1))}
  end

  defp extract(path), do: "json_extract(document, '" <> json_path(path) <> "')"
  defp json_type(path), do: "json_type(document, '" <> json_path(path) <> "')"
  defp json_path(path), do: "$" <> Enum.map_join(path, "", &(".\"" <> &1 <> "\""))
  defp quote_id(id), do: "\"" <> id <> "\""
  defp bind_value(true), do: 1
  defp bind_value(false), do: 0
  defp bind_value(value), do: value
  defp error(message), do: {:error, Selecto.Error.validation_error(message)}
end
