defmodule SelectoDBSQLite.Dialect do
  @moduledoc false

  @behaviour Selecto.DB.Dialect

  @impl true
  def render_lateral_subquery(fragment, selecto),
    do: SelectoDBSQLite.Lateral.render(fragment, selecto)

  alias Selecto.Dialect.TextSearch.{Predicate, Rank}
  alias Selecto.Dialect.Collection.Operation, as: CollectionOperation
  alias Selecto.Dialect.DateTime.Operation, as: DateTimeOperation
  alias Selecto.Dialect.Bucket.Expression, as: BucketExpression
  alias Selecto.Dialect.Predicate.Comparison

  @impl true
  def render_computed_value(fragment, selecto),
    do: SelectoDBSQLite.ComputedValues.render(fragment, selecto)

  alias Selecto.Dialect.Json.{
    ArrayContains,
    ArrayContainsAll,
    Contains,
    Extraction,
    KeyExists,
    Operation
  }

  @impl true
  def render_datetime_operation(%DateTimeOperation{} = operation, selecto),
    do: SelectoDBSQLite.Calendar.render(operation, selecto)

  @impl true
  def render_bucket(%BucketExpression{} = bucket, selecto),
    do: SelectoDBSQLite.Buckets.render(bucket, selecto)

  @impl true
  def render_text_normalization(normalization, _selecto),
    do: SelectoDBSQLite.Buckets.normalize(normalization)

  @impl true
  def render_comparison(%Comparison{} = comparison, _selecto) do
    operator = if comparison.operation == :case_insensitive_not_like, do: "NOT LIKE", else: "LIKE"
    {:ok, ["LOWER(", comparison.left, ") ", operator, " LOWER(", comparison.right, ")"]}
  end

  @impl true
  def render_json_extraction(%Extraction{} = fragment, selecto) do
    with :ok <- SelectoDBSQLite.RuntimeCapabilities.require_feature(selecto, :json) do
      value = "selecto_extract.value"
      path = json_path(fragment.path)
      extract = ["json_extract(", value, ", '", path, "')"]

      result =
        if fragment.as_text do
          [
            "CASE json_type(",
            value,
            ", '",
            path,
            "') WHEN 'true' THEN 'true' WHEN 'false' THEN 'false' ",
            "WHEN 'null' THEN NULL ELSE CAST(",
            extract,
            " AS TEXT) END"
          ]
        else
          extract
        end

      guarded = [
        "(SELECT CASE WHEN json_valid(",
        value,
        ") THEN ",
        result,
        " END FROM (SELECT ",
        column_ref(fragment),
        " AS value) AS selecto_extract)"
      ]

      {:ok, cast_json(guarded, fragment.cast)}
    end
  rescue
    error in ArgumentError -> json_validation_error(Exception.message(error), fragment.path)
  end

  @impl true
  def render_json_contains(%Contains{} = fragment, selecto) do
    with :ok <- SelectoDBSQLite.RuntimeCapabilities.require_feature(selecto, :json_contains) do
      SelectoDBSQLite.JsonContainment.render(column_ref(fragment), fragment.value)
    end
  end

  @impl true
  def render_json_key_exists(%KeyExists{} = fragment, selecto) do
    with :ok <- SelectoDBSQLite.RuntimeCapabilities.require_feature(selecto, :json) do
      {:ok,
       valid_json_predicate(fragment, [
         "json_type(",
         column_ref(fragment),
         ", '",
         json_path(fragment.path),
         "') IS NOT NULL"
       ])}
    end
  rescue
    error in ArgumentError -> json_validation_error(Exception.message(error), fragment.path)
  end

  @impl true
  def render_json_array_contains(%ArrayContains{value: values} = fragment, selecto)
      when is_list(values) do
    render_array_members(fragment, values, " OR ", "0", selecto)
  end

  def render_json_array_contains(%ArrayContains{} = fragment, selecto) do
    render_array_members(fragment, [fragment.value], " OR ", "0", selecto)
  end

  @impl true
  def render_json_array_contains_all(%ArrayContainsAll{} = fragment, selecto) do
    render_array_members(fragment, fragment.values, " AND ", "1", selecto)
  end

  defp render_array_members(fragment, values, operator, empty, selecto) when is_list(values) do
    with :ok <- SelectoDBSQLite.RuntimeCapabilities.require_feature(selecto, :json),
         true <- Enum.all?(values, &json_scalar?/1) do
      members =
        Enum.map(values, fn value ->
          [
            "EXISTS (SELECT 1 FROM json_each(",
            column_ref(fragment),
            ", '",
            json_path(fragment.path),
            "') AS selecto_json_member WHERE ",
            typed_json_match("selecto_json_member.type", "selecto_json_member.value", value),
            ")"
          ]
        end)

      predicate = if members == [], do: empty, else: Enum.intersperse(members, operator)

      {:ok,
       valid_json_predicate(fragment, [
         "json_type(",
         column_ref(fragment),
         ", '",
         json_path(fragment.path),
         "') = 'array' AND (",
         predicate,
         ")"
       ])}
    else
      {:error, _} = error ->
        error

      _ ->
        json_validation_error("SQLite JSON array membership supports only scalar values", values)
    end
  rescue
    error in ArgumentError -> json_validation_error(Exception.message(error), fragment.path)
  end

  defp render_array_members(_fragment, values, _operator, _empty, _selecto),
    do: json_validation_error("SQLite JSON array membership requires a list of values", values)

  defp valid_json_predicate(fragment, predicate),
    do: [
      "(CASE WHEN ",
      column_ref(fragment),
      " IS NULL THEN NULL WHEN json_valid(",
      column_ref(fragment),
      ") THEN (",
      predicate,
      ") ELSE 0 END)"
    ]

  defp typed_json_match(type, _value, :object), do: [type, " = 'object'"]
  defp typed_json_match(type, _value, nil), do: [type, " = 'null'"]
  defp typed_json_match(type, _value, true), do: [type, " = 'true'"]
  defp typed_json_match(type, _value, false), do: [type, " = 'false'"]

  defp typed_json_match(type, value, expected) when is_number(expected),
    do: ["(", type, " IN ('integer', 'real') AND ", value, " = ", {:param, expected}, ")"]

  defp typed_json_match(type, value, expected) when is_binary(expected),
    do: ["(", type, " = 'text' AND ", value, " = ", {:param, expected}, ")"]

  defp json_scalar?(value),
    do: is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value)

  defp json_validation_error(message, value),
    do:
      {:error,
       Selecto.Error.validation_error(message, %{
         unsupported_feature: :json_contains,
         value: value
       })}

  @impl true
  def render_json_operation(%Operation{} = operation, selecto) do
    with :ok <- SelectoDBSQLite.RuntimeCapabilities.require_feature(selecto, :json) do
      case operation.operation do
        :json_extract ->
          operation_extraction(operation, false, selecto)

        :json_extract_text ->
          operation_extraction(operation, true, selecto)

        :json_contains ->
          render_json_contains(operation_contains(operation), selecto)

        :json_agg ->
          {:ok, ["json_group_array(", operation_column(operation), ")"]}

        :json_build_object ->
          {:ok, ["json_object(", Map.fetch!(operation.options, :pairs_sql), ")"]}

        :json_empty_array ->
          {:ok, "'[]'"}

        kind when kind in [:json_exists, :json_path_exists] ->
          render_json_key_exists(operation_key_exists(operation), selecto)

        :json_typeof ->
          {:ok, json_path_function("json_type", operation)}

        :json_array_length ->
          {:ok, json_path_function("json_array_length", operation)}

        _operation ->
          {:error,
           Selecto.Error.validation_error("SQLite does not support this JSON operation", %{
             operation: operation.operation,
             unsupported_feature: :json_operation
           })}
      end
    end
  end

  @impl true
  def render_collection_operation(%CollectionOperation{} = operation, selecto),
    do: SelectoDBSQLite.Collections.render(operation, selecto)

  @impl true
  def render_table_function_join(join, selecto),
    do: SelectoDBSQLite.Collections.join(join, selecto)

  defp operation_extraction(operation, as_text, selecto) do
    render_json_extraction(
      %Extraction{
        column: operation.column,
        path: parse_operation_path(operation.path),
        as_text: as_text,
        table_alias: operation.table_alias
      },
      selecto
    )
  end

  defp operation_contains(operation) do
    %Contains{
      column: operation.column,
      value: operation.value,
      table_alias: operation.table_alias
    }
  end

  defp operation_key_exists(operation) do
    %KeyExists{
      column: operation.column,
      path: parse_operation_path(operation.path),
      table_alias: operation.table_alias
    }
  end

  defp json_path_function(function, %{path: nil} = operation),
    do: [function, "(", operation_column(operation), ")"]

  defp json_path_function(function, operation) do
    [
      function,
      "(",
      operation_column(operation),
      ", '",
      operation.path |> parse_operation_path() |> json_path(),
      "')"
    ]
  end

  defp operation_column(%{options: options}) when is_map_key(options, :column_sql),
    do: Map.fetch!(options, :column_sql)

  defp operation_column(%{column: column, table_alias: nil}),
    do: SelectoDBSQLite.Adapter.quote_identifier(column)

  defp operation_column(%{column: column, table_alias: table_alias}) do
    [
      SelectoDBSQLite.Adapter.quote_identifier(table_alias),
      ".",
      SelectoDBSQLite.Adapter.quote_identifier(column)
    ]
  end

  defp parse_operation_path(nil), do: []

  defp parse_operation_path(path) do
    path
    |> String.replace_prefix("$.", "")
    |> String.split(~r/[\.\[\]]/, trim: true)
  end

  defp column_ref(%{column: column, table_alias: nil}),
    do: SelectoDBSQLite.Adapter.quote_identifier(column)

  defp column_ref(%{column: column, table_alias: table_alias}) do
    [
      SelectoDBSQLite.Adapter.quote_identifier(table_alias),
      ".",
      SelectoDBSQLite.Adapter.quote_identifier(column)
    ]
  end

  defp json_path(path) do
    path
    |> Enum.reduce("$", fn segment, acc ->
      case Integer.parse(to_string(segment)) do
        {index, ""} -> acc <> "[#{index}]"
        _ -> acc <> "." <> safe_segment!(segment)
      end
    end)
    |> escape_literal()
  end

  defp safe_segment!(segment) do
    segment = to_string(segment)

    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, segment),
      do: segment,
      else: raise(ArgumentError, "invalid JSON path segment: #{inspect(segment)}")
  end

  defp cast_json(extraction, nil), do: extraction
  defp cast_json(extraction, :integer), do: ["CAST(", extraction, " AS INTEGER)"]
  defp cast_json(extraction, :decimal), do: ["CAST(", extraction, " AS NUMERIC)"]
  defp cast_json(extraction, :float), do: ["CAST(", extraction, " AS REAL)"]
  defp cast_json(extraction, :boolean), do: ["CAST(", extraction, " AS INTEGER)"]

  defp cast_json(extraction, cast) when cast in [:date, :datetime, :utc_datetime],
    do: ["CAST(", extraction, " AS TEXT)"]

  defp cast_json(_extraction, cast),
    do: raise(ArgumentError, "unsupported SQLite JSON cast: #{inspect(cast)}")

  defp escape_literal(value), do: value |> to_string() |> String.replace("'", "''")

  @impl true
  def render_text_search_predicate(%Predicate{} = predicate, selecto) do
    if SelectoDBSQLite.FtsIndex.declared?(selecto),
      do: render_external_predicate(predicate, selecto),
      else: render_root_predicate(predicate, selecto)
  end

  defp render_external_predicate(predicate, selecto) do
    with :ok <- simple_configuration(predicate.configuration),
         {:ok, index} <- SelectoDBSQLite.FtsIndex.verify(selecto, predicate.fields),
         {:ok, query} <- SelectoDBSQLite.FtsIndex.query(predicate.query, predicate.mode) do
      {:ok,
       [
         "EXISTS (SELECT 1 FROM ",
         main_index(index),
         " WHERE ",
         index_name(index),
         " MATCH ",
         SelectoDBSQLite.FtsIndex.match_query(index.fields, query),
         " AND ",
         index_name(index),
         ".rowid = selecto_root.",
         quoted(index.key),
         ")"
       ]}
    end
  end

  defp render_root_predicate(predicate, selecto) do
    with :ok <- require_fields(predicate.fields),
         :ok <- validate_mode(predicate.mode),
         :ok <- require_fts_fields(predicate.fields),
         :ok <- ensure_runtime_available(selecto) do
      query = search_query(predicate.query, predicate.mode)

      clauses =
        predicate.selectors
        |> Enum.map(fn selector -> [selector, " MATCH ", {:param, query}] end)
        |> Enum.intersperse(" OR ")

      case clauses do
        [clause] -> {:ok, [" ", clause, " "]}
        _clauses -> {:ok, [" (", clauses, ") "]}
      end
    end
  end

  @impl true
  def render_text_search_rank(%Rank{} = rank, selecto) do
    if SelectoDBSQLite.FtsIndex.declared?(selecto),
      do: render_external_rank(rank, selecto),
      else: render_root_rank(rank, selecto)
  end

  defp render_external_rank(rank, selecto) do
    with :ok <- simple_configuration(rank.configuration),
         :ok <- external_weights(rank.weights),
         {:ok, index} <- SelectoDBSQLite.FtsIndex.verify(selecto, rank.fields),
         {:ok, query} <- SelectoDBSQLite.FtsIndex.query(rank.query, rank.mode) do
      expression = [
        "(SELECT -bm25(",
        index_name(index),
        ") FROM ",
        main_index(index),
        " WHERE ",
        index_name(index),
        " MATCH ",
        SelectoDBSQLite.FtsIndex.match_query(index.fields, query),
        " AND ",
        index_name(index),
        ".rowid = selecto_root.",
        quoted(index.key),
        ")"
      ]

      {:ok, {:field, {:custom_sql, expression, %{}}, rank.alias}}
    end
  end

  defp main_index(index), do: ["main.", index_name(index)]
  defp index_name(index), do: quoted(index.table)
  defp quoted(identifier), do: SelectoDBSQLite.Adapter.quote_identifier(identifier)
  defp simple_configuration(config) when config in [nil, "simple"], do: :ok

  defp simple_configuration(_config),
    do: error("SQLite FTS5 requires simple search configuration")

  defp external_weights([]), do: :ok

  defp external_weights(_weights),
    do: error("SQLite external FTS5 rank does not accept custom weights")

  defp render_root_rank(rank, selecto) do
    with :ok <- require_rank_fields(rank.fields),
         :ok <- validate_weights(rank.weights),
         :ok <- ensure_runtime_available(selecto),
         {:ok, source_table} <- rank_source_table(selecto, rank.fields) do
      weight_args =
        case rank.weights do
          [] -> []
          weights -> [", ", Enum.intersperse(Enum.map(weights, &number_sql/1), ", ")]
        end

      {:ok,
       {:custom_sql,
        [
          "bm25(",
          Selecto.Builder.Sql.Helpers.quote_identifier(selecto, source_table),
          weight_args,
          ") AS ",
          Selecto.Builder.Sql.Helpers.force_quote_identifier(selecto, rank.alias)
        ], %{}}}
    end
  end

  defp require_fields([]), do: error("SQLite text search requires at least one field")
  defp require_fields(_fields), do: :ok

  defp require_rank_fields([]), do: error("SQLite text_search_rank/3 requires at least one field")
  defp require_rank_fields(_fields), do: :ok

  defp validate_mode(mode) when mode in [nil, :websearch, :boolean, :phrase], do: :ok

  defp validate_mode(mode),
    do: error("SQLite FTS5 does not support this text-search mode", mode: mode)

  defp require_fts_fields(fields) do
    invalid = Enum.reject(fields, &fts_field?(&1.config))

    if invalid == [],
      do: :ok,
      else:
        error("SQLite text search requires FTS5-configured fields",
          fields: Enum.map(invalid, & &1.name)
        )
  end

  defp ensure_runtime_available(selecto),
    do: SelectoDBSQLite.RuntimeCapabilities.require_feature(selecto, :text_search)

  defp search_query(value, :phrase) when is_binary(value) do
    if String.starts_with?(value, "\"") and String.ends_with?(value, "\"") do
      value
    else
      escaped = String.replace(value, "\"", "\"\"")
      ~s("#{escaped}")
    end
  end

  defp search_query(value, _mode), do: value

  defp validate_weights(weights) when is_list(weights) do
    if Enum.all?(weights, &is_number/1),
      do: :ok,
      else: error("SQLite text_search_rank/3 weights must contain only numbers")
  end

  defp validate_weights(_weights),
    do: error("SQLite text_search_rank/3 :weights must be a list of numbers")

  defp number_sql(number) when is_integer(number), do: Integer.to_string(number)
  defp number_sql(number) when is_float(number), do: Float.to_string(number)

  defp rank_source_table(selecto, fields) do
    with {:ok, configs} <- rank_field_configs(selecto, fields) do
      configs
      |> Enum.map(fn conf -> Map.get(conf, :requires_join, :selecto_root) end)
      |> Enum.map(fn
        :selecto_root -> "selecto_root"
        value -> to_string(value)
      end)
      |> Enum.uniq()
      |> case do
        ["selecto_root"] ->
          {:ok, selecto.domain.source.source_table}

        aliases ->
          error("SQLite text_search_rank/3 requires fields from the root FTS table",
            aliases: aliases
          )
      end
    end
  end

  defp rank_field_configs(selecto, fields) do
    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, configs} ->
      case root_column_conf(selecto, field) do
        nil ->
          {:halt, error("SQLite text_search_rank/3 field not found", field: field)}

        conf ->
          if fts_field?(conf),
            do: {:cont, {:ok, configs ++ [conf]}},
            else:
              {:halt,
               error("SQLite text_search_rank/3 field is not configured for FTS5", field: field)}
      end
    end)
  end

  defp fts_field?(conf) do
    Map.get(conf, :type) == :fts5 or Map.get(conf, :sqlite_fts5) == true or
      Map.get(conf, :text_search_backend) == :fts5
  end

  defp root_column_conf(selecto, field) do
    columns = selecto |> Map.get(:config, %{}) |> Map.get(:columns, %{})
    Map.get(columns, field) || Map.get(columns, safe_existing_atom(field))
  end

  defp safe_existing_atom(field) when is_binary(field) do
    try do
      String.to_existing_atom(field)
    rescue
      ArgumentError -> nil
    end
  end

  defp safe_existing_atom(_field), do: nil

  defp error(message, details \\ []) do
    {:error,
     Selecto.Error.validation_error(
       message,
       Map.new([unsupported_feature: :text_search] ++ details)
     )}
  end
end
