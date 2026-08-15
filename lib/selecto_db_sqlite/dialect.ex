defmodule SelectoDBSQLite.Dialect do
  @moduledoc false

  @behaviour Selecto.DB.Dialect

  alias Selecto.Dialect.TextSearch.{Predicate, Rank}
  alias Selecto.Dialect.Collection.Operation, as: CollectionOperation
  alias Selecto.Dialect.DateTime.Operation, as: DateTimeOperation
  alias Selecto.Dialect.Predicate.Comparison

  alias Selecto.Dialect.Json.{
    ArrayContains,
    ArrayContainsAll,
    Contains,
    Extraction,
    KeyExists,
    Operation
  }

  @impl true
  def render_datetime_operation(%DateTimeOperation{operation: :format} = operation, _selecto) do
    if temporal_conversion_requested?(operation.options) do
      unsupported_datetime(operation)
    else
      {:ok,
       SelectoDBSQLite.Adapter.format_datetime(
         operation.expression,
         Map.fetch!(operation.options, :format)
       )}
    end
  end

  def render_datetime_operation(%DateTimeOperation{} = operation, _selecto),
    do: unsupported_datetime(operation)

  @impl true
  def render_comparison(%Comparison{} = comparison, _selecto) do
    operator = if comparison.operation == :case_insensitive_not_like, do: "NOT LIKE", else: "LIKE"
    {:ok, ["LOWER(", comparison.left, ") ", operator, " LOWER(", comparison.right, ")"]}
  end

  @impl true
  def render_json_extraction(%Extraction{} = fragment, _selecto) do
    extraction = ["json_extract(", column_ref(fragment), ", '", json_path(fragment.path), "')"]
    {:ok, cast_json(extraction, fragment.cast)}
  end

  @impl true
  def render_json_contains(%Contains{value: value} = fragment, _selecto) when is_map(value) do
    clauses =
      value
      |> flatten_object([])
      |> Enum.map(fn {path, path_value} ->
        [
          "json_extract(",
          column_ref(fragment),
          ", '",
          json_path(path),
          "') = ",
          literal(path_value)
        ]
      end)
      |> Enum.intersperse(" AND ")

    {:ok, clauses}
  end

  def render_json_contains(%Contains{value: value}, _selecto) do
    {:error,
     Selecto.Error.validation_error(
       "SQLite JSON containment supports only object comparisons",
       %{unsupported_feature: :json_contains, value: value}
     )}
  end

  @impl true
  def render_json_key_exists(%KeyExists{} = fragment, _selecto) do
    {:ok,
     [
       "json_type(",
       column_ref(fragment),
       ", '",
       json_path(fragment.path),
       "') IS NOT NULL"
     ]}
  end

  @impl true
  def render_json_array_contains(%ArrayContains{value: values} = fragment, selecto)
      when is_list(values) do
    values
    |> Enum.map(fn value ->
      render_json_array_contains(%{fragment | value: value}, selecto) |> elem(1)
    end)
    |> Enum.intersperse(" OR ")
    |> then(&{:ok, &1})
  end

  def render_json_array_contains(%ArrayContains{} = fragment, _selecto) do
    {:ok,
     [
       "EXISTS (SELECT 1 FROM json_each(",
       column_ref(fragment),
       ", '",
       json_path(fragment.path),
       "') WHERE value = ",
       literal(fragment.value),
       ")"
     ]}
  end

  @impl true
  def render_json_array_contains_all(%ArrayContainsAll{} = fragment, selecto) do
    fragment.values
    |> Enum.map(fn value ->
      render_json_array_contains(
        %ArrayContains{
          column: fragment.column,
          path: fragment.path,
          value: value,
          table_alias: fragment.table_alias
        },
        selecto
      )
      |> elem(1)
    end)
    |> Enum.intersperse(" AND ")
    |> then(&{:ok, &1})
  end

  @impl true
  def render_json_operation(%Operation{} = operation, selecto) do
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

  @impl true
  def render_collection_operation(%CollectionOperation{} = operation, _selecto) do
    case operation.operation do
      :array_agg when operation.order_by in [nil, []] ->
        distinct = if operation.distinct, do: "DISTINCT ", else: ""
        {:ok, ["json_group_array(", distinct, operation.column, ")"]}

      :string_agg when not operation.distinct and operation.order_by in [nil, []] ->
        delimiter = Map.get(operation.options, :delimiter, ",")

        {:ok,
         {[
            "group_concat(",
            operation.column,
            ", ",
            {:param, delimiter},
            ")"
          ], [delimiter]}}

      unsupported ->
        {:error,
         Selecto.Error.validation_error("SQLite does not support this collection operation", %{
           operation: unsupported,
           unsupported_feature: :collection_operation
         })}
    end
  end

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

  defp flatten_object(map, prefix) do
    Enum.flat_map(map, fn
      {key, nested} when is_map(nested) ->
        flatten_object(nested, prefix ++ [to_string(key)])

      {key, value} when is_list(value) ->
        raise Selecto.Error.to_exception(
                Selecto.Error.validation_error(
                  "SQLite JSON containment does not support nested arrays",
                  %{path: prefix ++ [to_string(key)]}
                )
              )

      {key, value} ->
        [{prefix ++ [to_string(key)], value}]
    end)
  end

  defp literal(value) when is_binary(value), do: ["'", escape_literal(value), "'"]
  defp literal(value) when is_integer(value), do: Integer.to_string(value)
  defp literal(value) when is_float(value), do: Float.to_string(value)
  defp literal(true), do: "1"
  defp literal(false), do: "0"
  defp literal(nil), do: "NULL"
  defp literal(value), do: ["'", value |> Jason.encode!() |> escape_literal(), "'"]

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
    with :ok <- require_rank_fields(rank.fields),
         :ok <- validate_weights(rank.weights),
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

  defp ensure_runtime_available(selecto) do
    adapter = Map.get(selecto, :adapter)
    connection = Selecto.Runtime.Context.connection(selecto)

    cond do
      connection in [nil, [], %{}] ->
        :ok

      not Selecto.AdapterSupport.callback_available?(adapter, :fts5_available?, 1) ->
        :ok

      adapter.fts5_available?(connection) ->
        :ok

      true ->
        error("SQLite FTS5 is not available on the current connection", runtime: :unavailable)
    end
  end

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

  defp temporal_conversion_requested?(options) do
    Map.get(options, :epoch_storage) not in [nil, false] or
      Map.get(options, :timezone) not in [nil, ""]
  end

  defp unsupported_datetime(operation) do
    {:error,
     Selecto.Error.validation_error("SQLite does not support this datetime operation", %{
       operation: operation.operation,
       unsupported_feature: :datetime_operation
     })}
  end

  defp error(message, details \\ []) do
    {:error,
     Selecto.Error.validation_error(
       message,
       Map.new([unsupported_feature: :text_search] ++ details)
     )}
  end
end
