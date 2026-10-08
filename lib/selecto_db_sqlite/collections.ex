defmodule SelectoDBSQLite.Collections do
  @moduledoc false
  alias Selecto.Dialect.Collection.Operation
  alias Selecto.Dialect.TableFunction.Join
  alias SelectoDBSQLite.{Adapter, RuntimeCapabilities}

  def render(%Operation{} = operation, selecto) do
    with :ok <- RuntimeCapabilities.require_feature(selecto, :json) do
      render_operation(operation, selecto)
    end
  end

  defp render_operation(%Operation{operation: kind} = op, selecto)
       when kind in [:array_agg, :array_agg_distinct] do
    with {:ok, ordering} <- ordering(op.order_by, selecto) do
      distinct = if op.distinct or kind == :array_agg_distinct, do: "DISTINCT ", else: ""
      {:ok, ["json_group_array(", distinct, op.column, ordering, ")"]}
    end
  end

  defp render_operation(%Operation{operation: :string_agg} = op, selecto) do
    delimiter = Map.get(op.options, :delimiter, ",")

    with true <- is_binary(delimiter),
         {:ok, ordering} <- ordering(op.order_by, selecto) do
      cond do
        op.distinct == true and delimiter != "," ->
          unsupported(:distinct_string_agg_delimiter)

        op.distinct ->
          {:ok, ["group_concat(DISTINCT ", op.column, ordering, ")"]}

        true ->
          {:ok,
           {["group_concat(", op.column, ", ", {:param, delimiter}, ordering, ")"], [delimiter]}}
      end
    else
      {:error, _} = error -> error
      _ -> unsupported(:string_agg_delimiter)
    end
  end

  defp render_operation(%Operation{operation: :unnest} = op, _selecto),
    do: {:ok, ["json_each(", array_source(op.column), ")"]}

  defp render_operation(%Operation{operation: operation} = op, _selecto)
       when operation in [:cardinality, :array_length] do
    if operation == :cardinality or op.dimension in [nil, 1] do
      {:ok,
       single_value(op.column, [
         "CASE WHEN json_valid(selecto_array.value) THEN CASE WHEN json_type(selecto_array.value) = 'array' THEN json_array_length(selecto_array.value) END END"
       ])}
    else
      unsupported(:multidimensional_array)
    end
  end

  defp render_operation(%Operation{operation: :array, value: values}, _selecto)
       when is_list(values) do
    case Jason.encode(values) do
      {:ok, encoded} -> {:ok, {["json(", {:param, encoded}, ")"], [encoded]}}
      _ -> unsupported(:array_values)
    end
  end

  defp render_operation(%Operation{operation: :array_constructor, value: values}, _selecto),
    do: {:ok, ["json_array(", values || [], ")"]}

  defp render_operation(%Operation{operation: :array_contains, value: values} = op, _selecto)
       when is_list(values),
       do: SelectoDBSQLite.JsonContainment.render(op.column, values)

  defp render_operation(%Operation{operation: operation, value: values} = op, _selecto)
       when operation in [:array_overlap, :array_contained, :array_eq] and is_list(values) do
    if Enum.all?(values, &(is_nil(&1) or is_boolean(&1) or is_number(&1) or is_binary(&1))) do
      case Jason.encode(values) do
        {:ok, encoded} ->
          lhs = "selecto_arrays.lhs"
          rhs = "selecto_arrays.rhs"

          equal =
            "((l.type = r.type OR (l.type IN ('integer','real') AND r.type IN ('integer','real'))) AND l.value IS r.value)"

          predicate =
            case operation do
              :array_overlap ->
                [
                  "EXISTS (SELECT 1 FROM json_each(",
                  lhs,
                  ") AS l JOIN json_each(",
                  rhs,
                  ") AS r ON ",
                  equal,
                  ")"
                ]

              :array_contained ->
                [
                  "NOT EXISTS (SELECT 1 FROM json_each(",
                  lhs,
                  ") AS l WHERE NOT EXISTS (SELECT 1 FROM json_each(",
                  rhs,
                  ") AS r WHERE ",
                  equal,
                  "))"
                ]

              :array_eq ->
                [
                  "json_array_length(",
                  lhs,
                  ") = json_array_length(",
                  rhs,
                  ") AND NOT EXISTS (SELECT 1 FROM json_each(",
                  lhs,
                  ") AS l WHERE NOT EXISTS (SELECT 1 FROM json_each(",
                  rhs,
                  ") AS r WHERE l.key = r.key AND ",
                  equal,
                  "))"
                ]
            end

          {:ok,
           [
             "(SELECT CASE WHEN ",
             lhs,
             " IS NULL THEN NULL WHEN json_valid(",
             lhs,
             ") THEN CASE WHEN json_type(",
             lhs,
             ") = 'array' THEN (",
             predicate,
             ") ELSE 0 END ELSE 0 END FROM (SELECT ",
             op.column,
             " AS lhs, ",
             {:param, encoded},
             " AS rhs) AS selecto_arrays)"
           ]}

        _ ->
          unsupported(:array_values)
      end
    else
      unsupported(:multidimensional_array)
    end
  end

  defp render_operation(%Operation{operation: operation}, _selecto), do: unsupported(operation)

  def join(%Join{source_kind: kind, join_type: join_type} = join, selecto)
      when kind in [:table_function, nil] and join_type in [:cross, :inner, :left] do
    with :ok <- RuntimeCapabilities.require_feature(selecto, :json_rowset) do
      prefix =
        case join_type do
          :cross -> "CROSS JOIN "
          :inner -> "INNER JOIN "
          :left -> "LEFT JOIN "
        end

      on = if join_type == :cross, do: "", else: " ON true"
      # Native SQLite table functions correlate without LATERAL. Core maps the
      # requested ordinal selector to key + 1; SQLite has no alias column list.
      {:ok, [prefix, join.source_sql, " AS ", Adapter.quote_identifier(join.alias), on]}
    end
  end

  def join(%Join{} = join, _selecto),
    do: unsupported({:table_function_join, join.join_type, join.source_kind})

  defp ordering(value, _selecto) when value in [nil, []], do: {:ok, []}

  defp ordering(terms, selecto) when is_list(terms) do
    with true <- Enum.all?(terms, &match?({_, direction} when direction in [:asc, :desc], &1)),
         :ok <- RuntimeCapabilities.require_feature(selecto, :ordered_aggregate) do
      {:ok,
       [
         " ORDER BY ",
         Enum.intersperse(
           Enum.map(terms, fn {sql, direction} -> [sql, " ", Atom.to_string(direction)] end),
           ", "
         )
       ]}
    else
      {:error, _} = error -> error
      _ -> unsupported(:collection_order)
    end
  end

  defp ordering(_, _), do: unsupported(:collection_order)

  defp array_source(source),
    do:
      single_value(source, [
        "CASE WHEN json_valid(selecto_array.value) THEN CASE WHEN json_type(selecto_array.value) = 'array' THEN selecto_array.value ELSE '[]' END ELSE '[]' END"
      ])

  defp single_value(source, result),
    do: ["(SELECT ", result, " FROM (SELECT ", source, " AS value) AS selecto_array)"]

  defp unsupported(operation),
    do:
      {:error,
       Selecto.Error.validation_error("SQLite does not support this collection operation", %{
         operation: operation,
         unsupported_feature: :collection_operation
       })}
end
