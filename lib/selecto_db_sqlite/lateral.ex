defmodule SelectoDBSQLite.Lateral do
  @moduledoc false
  alias Selecto.Domain.Shared.Map, as: DomainMap
  alias SelectoDBSQLite.{Adapter, QueryGuard, RuntimeCapabilities}

  @directions [
    :asc,
    :desc,
    :asc_nulls_first,
    :asc_nulls_last,
    :desc_nulls_first,
    :desc_nulls_last
  ]
  @set_keys [
    :selected,
    :filtered,
    :required_filters,
    :order_by,
    :group_by,
    :post_retarget_filters,
    :limit,
    :offset,
    :query_member_tenant_field
  ]

  # SQLite has no LATERAL keyword. A flat child row query can instead be ranked
  # once per correlation key, then joined on those keys and its per-key bounds.
  # Direct key projections preserve SQLite column affinity and collation. Equal
  # affinities are required: otherwise comparison conversion can match multiple
  # storage-class partitions and violate the original per-parent limit.
  def render(
        %{join_type: type, alias: name, options: %{query: %Selecto{} = child}},
        %Selecto{} = parent
      )
      when type in [:left, :inner] do
    with true <- identifier?(name),
         true <- child.adapter == parent.adapter and parent.adapter == Adapter,
         true <- connection(child) == connection(parent),
         :ok <- flat_shape(child),
         {:ok, outputs} <- projections(child),
         {:ok, correlations, remaining} <- correlations(child, parent),
         true <- correlations != [] and length(correlations) <= 32,
         :ok <- ordering(child),
         :ok <- prove_keys(parent, child, correlations),
         :ok <- window_support(child) do
      lower(type, to_string(name), parent, child, outputs, correlations, remaining)
    else
      {:error, _} = error -> error
      _ -> error("SQLite lateral query is outside the bounded correlated row shape")
    end
  end

  def render(_fragment, _parent),
    do: error("SQLite lateral queries support only flat LEFT and INNER child row queries")

  defp flat_shape(child) do
    valid =
      Enum.all?(Map.keys(child.set), &(&1 in @set_keys)) and
        Enum.all?([:group_by, :post_retarget_filters], &(Map.get(child.set, &1, []) == [])) and
        Enum.all?([:limit, :offset], fn key ->
          value = Map.get(child.set, key)
          is_nil(value) or (is_integer(value) and value >= 0 and value <= 2_147_483_647)
        end) and map_size(Selecto.joins(child)) == 0 and
        identifier?(Selecto.source_table(child)) and
        Enum.all?(Map.get(child.domain, :required_filters, []), &predicate?(child, &1, 0))

    if valid, do: :ok, else: error("SQLite lateral child must be an ordinary unjoined row query")
  end

  defp projections(child) do
    results = Enum.map(Map.get(child.set, :selected, []), &projection(child, &1))
    outputs = for {:ok, name} <- results, do: name
    identities = Enum.map(outputs, &identity/1)

    if results != [] and length(results) <= 128 and length(outputs) == length(results) and
         length(Enum.uniq(identities)) == length(identities),
       do: {:ok, outputs},
       else: error("SQLite lateral projections require distinct stored field outputs")
  end

  defp projection(child, {:field, field, name}) do
    if stored?(child, field) and identifier?(name), do: {:ok, to_string(name)}, else: :error
  end

  defp projection(child, {:field, field}), do: projection(child, field)

  defp projection(child, field) do
    if stored?(child, field), do: {:ok, to_string(field)}, else: :error
  end

  defp correlations(child, parent) do
    Enum.reduce_while([:filtered, :required_filters], {:ok, [], %{}}, fn key, {:ok, all, kept} ->
      filters = Map.get(child.set, key, [])

      if is_list(filters) and length(filters) <= 128 do
        result =
          Enum.reduce_while(filters, {:ok, [], []}, fn filter, {:ok, pairs, rest} ->
            case correlation(filter) do
              {field, "selecto_root." <> root} ->
                if stored?(child, field) and stored?(parent, root),
                  do: {:cont, {:ok, [{field, root} | pairs], rest}},
                  else: {:halt, :error}

              _ ->
                if predicate?(child, filter, 0),
                  do: {:cont, {:ok, pairs, [filter | rest]}},
                  else: {:halt, :error}
            end
          end)

        case result do
          {:ok, pairs, rest} ->
            {:cont, {:ok, all ++ Enum.reverse(pairs), Map.put(kept, key, Enum.reverse(rest))}}

          _ ->
            {:halt,
             error(
               "SQLite lateral correlations must be positive top-level root equality predicates"
             )}
        end
      else
        {:halt, error("SQLite lateral predicate count exceeds its bound")}
      end
    end)
  end

  defp correlation({field, {:ref, reference}}), do: {field, reference}

  defp correlation({field, {op, {:ref, reference}}}) when op in [:eq, :=, "="],
    do: {field, reference}

  defp correlation(_filter), do: nil

  defp predicate?(_child, _filter, depth) when depth > 16, do: false

  defp predicate?(child, {op, filters}, depth) when op in [:and, :or] and is_list(filters),
    do: length(filters) <= 128 and Enum.all?(filters, &predicate?(child, &1, depth + 1))

  defp predicate?(child, {:not, filter}, depth), do: predicate?(child, filter, depth + 1)

  defp predicate?(child, {field, {op, value}}, _depth)
       when op in [
              :eq,
              :ne,
              :=,
              :!=,
              :gt,
              :lt,
              :gte,
              :lte,
              :>,
              :<,
              :>=,
              :<=,
              "=",
              "!=",
              ">",
              "<",
              ">=",
              "<=",
              :like,
              :not_like
            ],
       do: stored?(child, field) and scalar?(value)

  defp predicate?(child, {field, {:in, values}}, _depth) when is_list(values),
    do: stored?(child, field) and length(values) <= 128 and Enum.all?(values, &scalar?/1)

  defp predicate?(child, {field, value}, _depth),
    do: stored?(child, field) and (scalar?(value) or value in [:null, :not_null])

  defp predicate?(_child, _filter, _depth), do: false

  defp scalar?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: true

  defp scalar?(%Decimal{coef: coefficient}) when is_integer(coefficient), do: true
  defp scalar?(%Date{}), do: true
  defp scalar?(%NaiveDateTime{}), do: true
  defp scalar?(%DateTime{}), do: true
  defp scalar?(_value), do: false

  defp ordering(child) do
    orders = Map.get(child.set, :order_by, [])

    valid =
      is_list(orders) and length(orders) <= 128 and
        Enum.all?(orders, fn
          {field, direction} when direction in @directions -> stored?(child, field)
          {direction, field} when direction in @directions -> stored?(child, field)
          field -> stored?(child, field)
        end)

    if valid, do: :ok, else: error("SQLite lateral ordering requires stored child fields")
  end

  defp stored?(query, field) when is_binary(field) or is_atom(field) do
    authored =
      case DomainMap.fetch_key(DomainMap.map_value(source(query), :columns) || %{}, field) do
        {:ok, value} when is_map(value) -> value
        _ -> nil
      end

    conf = if identifier?(field), do: Selecto.field(query, field)

    is_map(authored) and is_map(conf) and conf[:requires_join] == :selecto_root and
      not Map.has_key?(conf, :computed) and not Map.has_key?(conf, :select) and
      identifier?(conf[:field]) and not Map.has_key?(authored, :computed) and
      not Map.has_key?(authored, "computed") and not Map.has_key?(authored, :select) and
      not Map.has_key?(authored, "select")
  end

  defp stored?(_query, _field), do: false

  defp prove_keys(parent, child, correlations) do
    db = connection(parent)

    if is_reference(db) or (is_map(db) and is_reference(db[:connection])) do
      QueryGuard.run(db, fn ->
        with {:ok, outer_columns} <- columns(db, Selecto.source_table(parent)),
             {:ok, child_columns} <- columns(db, Selecto.source_table(child)),
             true <-
               Enum.all?(
                 used_fields(child),
                 &(not is_nil(column_affinity(child_columns, physical(child, &1))))
               ),
             true <-
               Enum.all?(correlations, fn {field, root} ->
                 left = column_affinity(child_columns, physical(child, field))
                 right = column_affinity(outer_columns, physical(parent, root))
                 not is_nil(left) and left == right
               end) do
          :ok
        else
          {:error, _} = error ->
            error

          _ ->
            error("SQLite lateral correlation keys require equal native stored-column affinities")
        end
      end)
    else
      if db == :compile_only,
        do: :ok,
        else: error("SQLite lateral lowering requires an ordinary native connection")
    end
  end

  defp used_fields(child) do
    selected =
      Enum.map(child.set.selected, fn
        {:field, field, _name} -> field
        {:field, field} -> field
        field -> field
      end)

    orders =
      Enum.map(child.set.order_by, fn
        {field, direction} when direction in @directions -> field
        {direction, field} when direction in @directions -> field
        field -> field
      end)

    filters =
      Map.get(child.domain, :required_filters, []) ++
        child.set.filtered ++ Map.get(child.set, :required_filters, [])

    Enum.uniq(selected ++ orders ++ Enum.flat_map(filters, &filter_fields/1))
  end

  defp filter_fields({op, filters}) when op in [:and, :or],
    do: Enum.flat_map(filters, &filter_fields/1)

  defp filter_fields({:not, filter}), do: filter_fields(filter)
  defp filter_fields({field, _value}), do: [field]

  defp columns(db, table) do
    if identifier?(table) do
      table = to_string(table)

      with {:ok, main} <- rows(db, "SELECT name,type FROM main.sqlite_schema LIMIT 4097"),
           {:ok, temp} <- rows(db, "SELECT name,type FROM temp.sqlite_schema LIMIT 4097"),
           [] <- Enum.filter(temp, fn [name, _] -> identity(name) == identity(table) end),
           [[_, "table"]] <-
             Enum.filter(main, fn [name, _] -> identity(name) == identity(table) end),
           {:ok, listed} <- rows(db, "PRAGMA main.table_list('" <> table <> "')"),
           [["main", _, "table" | _]] <-
             Enum.filter(listed, fn [schema, name | _] ->
               schema == "main" and identity(name) == identity(table)
             end),
           {:ok, columns} <- rows(db, "PRAGMA main.table_xinfo('" <> table <> "')") do
        {:ok, columns}
      else
        _ -> error("SQLite lateral source requires an unshadowed ordinary main table")
      end
    else
      error("SQLite lateral source identifier is unavailable")
    end
  end

  defp column_affinity(columns, name) do
    case Enum.filter(columns, fn [_, field | _] -> identity(field) == identity(name) end) do
      [[_, _, type, _, _, _, 0]] -> affinity(type)
      _ -> nil
    end
  end

  defp affinity(type) do
    type = String.upcase(type, :ascii)

    cond do
      String.contains?(type, "INT") -> :integer
      Enum.any?(["CHAR", "CLOB", "TEXT"], &String.contains?(type, &1)) -> :text
      type == "" or String.contains?(type, "BLOB") -> :blob
      Enum.any?(["REAL", "FLOA", "DOUB"], &String.contains?(type, &1)) -> :real
      true -> :numeric
    end
  end

  defp rows(db, sql) do
    case Adapter.execute(db, sql, [], []) do
      {:ok, %{rows: rows}} when length(rows) <= 4096 -> {:ok, rows}
      _ -> error("SQLite lateral catalog inspection exceeded its bound")
    end
  end

  defp window_support(child) do
    if ranked?(child),
      do: RuntimeCapabilities.require_feature(child, :window_functions),
      else: :ok
  end

  defp ranked?(child), do: not is_nil(child.set[:limit]) or not is_nil(child.set[:offset])

  defp lower(type, name, parent, child, outputs, correlations, remaining) do
    reserved = outputs ++ Enum.map(Map.keys(child.config.columns), &to_string/1)

    {keys, reserved} =
      Enum.map_reduce(correlations, reserved, fn _, names ->
        alias_name = unused_alias(names, 0)
        {alias_name, [alias_name | names]}
      end)

    rank = unused_alias(reserved, 0)

    additions =
      Enum.zip_with(correlations, keys, fn {field, _}, name -> Selecto.Expr.as(field, name) end)

    set =
      child.set
      |> Map.merge(remaining)
      |> Map.put(:selected, child.set.selected ++ additions)
      |> Map.put(:order_by, [])
      |> Map.delete(:limit)
      |> Map.delete(:offset)

    set =
      if ranked?(child) do
        window = %Selecto.Window.Spec{
          function: :row_number,
          arguments: [],
          alias: rank,
          partition_by: Enum.map(correlations, &window_field(child, elem(&1, 0))),
          order_by: Enum.map(child.set.order_by, &window_order(child, &1))
        }

        Map.put(set, :window_functions, [window])
      else
        set
      end

    {sql, _aliases} =
      Selecto.Builder.Sql.build_iodata(%{child | set: set}, preserve_projection_aliases: true)

    conditions =
      Enum.zip_with(correlations, keys, fn {_, root}, key ->
        [ref(name, key), " = ", ref("selecto_root", physical(parent, root))]
      end)

    conditions = if ranked?(child), do: conditions ++ bounds(name, rank, child), else: conditions

    {:ok,
     [
       if(type == :left, do: "LEFT JOIN (", else: "INNER JOIN ("),
       sql,
       ") AS ",
       Adapter.quote_identifier(name),
       " ON ",
       Enum.intersperse(conditions, " AND ")
     ]}
  end

  defp bounds(name, rank, child) do
    offset = child.set[:offset] || 0
    lower = [ref(name, rank), " > ", {:param, offset}]

    case child.set[:limit] do
      nil -> [lower]
      limit -> [lower, [ref(name, rank), " <= ", {:param, offset + limit}]]
    end
  end

  defp window_order(child, {field, direction}) when direction in @directions,
    do: {window_field(child, field), direction |> to_string() |> String.replace("_", " ")}

  defp window_order(child, {direction, field}) when direction in @directions,
    do: window_order(child, {field, direction})

  # Ordinary core ORDER BY defaults to ASC NULLS FIRST.
  defp window_order(child, field), do: {window_field(child, field), "asc nulls first"}

  defp window_field(child, field),
    do: ref("selecto_root", physical(child, field)) |> IO.iodata_to_binary()

  defp unused_alias(names, index) do
    name = "__selecto_lateral_" <> Integer.to_string(index)

    if Enum.any?(names, &(identity(&1) == identity(name))),
      do: unused_alias(names, index + 1),
      else: name
  end

  defp ref(table, column),
    do: [Adapter.quote_identifier(table), ".", Adapter.quote_identifier(column)]

  defp physical(query, field), do: Selecto.field(query, field).field |> to_string()
  defp connection(query), do: Selecto.Runtime.Context.connection(query)
  defp source(query), do: DomainMap.map_value(query.domain, :source) || %{}
  defp identity(value), do: String.downcase(to_string(value), :ascii)

  defp identifier?(value) when is_atom(value) or is_binary(value),
    do:
      byte_size(to_string(value)) <= 128 and
        Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, to_string(value))

  defp identifier?(_value), do: false

  defp error(message),
    do:
      {:error,
       Selecto.Error.validation_error(message, %{
         adapter: :sqlite,
         unsupported_feature: :lateral_join
       })}
end
