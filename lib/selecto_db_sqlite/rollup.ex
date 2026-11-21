defmodule SelectoDBSQLite.Rollup do
  @moduledoc false

  # SQLite has no ROLLUP, CUBE or GROUPING SETS. Each grouping set of the
  # query (Selecto.GroupingSets.positions/1: a rollup's prefixes, a cube's
  # subsets, the declared sets) becomes one plain-grouped UNION ALL branch;
  # dimensions grouped away in a branch project NULL and GROUPING(...) is
  # the branch's constant mask (first argument most significant).

  alias Selecto.Builder.Sql
  alias Selecto.Builder.Sql.Select
  alias SelectoDBSQLite.{Adapter, RuntimeCapabilities}

  @max_dimensions 8
  # Declared grouping sets (at most 64 of them) may span more dimensions.
  @max_set_dimensions 64
  @max_selectors 64
  @directions [
    :asc,
    :desc,
    :asc_nulls_first,
    :asc_nulls_last,
    :desc_nulls_first,
    :desc_nulls_last
  ]
  @aggregate_functions ~w(COUNT SUM AVG MIN MAX)

  def render(selecto, opts) do
    mode = Selecto.GroupingSets.mode(selecto)

    try do
      render(selecto, opts, mode)
    catch
      {__MODULE__, :unsupported, message} -> refuse!(mode, message)
    end
  end

  defp render(selecto, opts, mode) do
    case RuntimeCapabilities.require_feature(selecto, mode) do
      :ok -> :ok
      {:error, error} -> Selecto.Builder.ScopeRefusal.unsupported!(error)
    end

    {dimensions, sets} = grouping!(mode, selecto.set.group_by)
    selectors = Map.get(selecto.set, :selected, [])
    validate_shape!(selecto, selectors)
    Enum.each(selectors, &validate_selector!(&1, dimensions))

    # Keep all original selector and dimension joins, including dimensions that
    # are neither projected nor retained in a subtotal. Removing such an INNER
    # JOIN changes the eligible source rows and silently widens the total.
    compiled = Enum.map(selectors, &Select.build(selecto, &1))

    joins =
      (compiled ++ Enum.map(dimensions, &Select.build(selecto, &1)))
      |> Enum.flat_map(fn {_, joins, _, _} -> List.wrap(joins) end)
      |> Kernel.++(List.wrap(Map.get(selecto.set, :active_joins, [])))
      |> Enum.uniq()

    aliases = Enum.map(compiled, fn {_, _, _, name} -> to_string(name) end)
    validate_aliases!(aliases)
    order = outer_order!(Map.get(selecto.set, :order_by, []), selectors, aliases)

    dimension_tuple = List.to_tuple(dimensions)

    {branches, resolved_joins} =
      Enum.map_reduce(sets, [], fn set, joins_acc ->
        retained = Enum.map(set, &elem(dimension_tuple, &1))

        selected =
          Enum.zip(selectors, aliases)
          |> Enum.map(fn {selector, name} ->
            {:field, rewrite(selector, dimensions, retained), name}
          end)

        # This internal aggregate also gives the empty-input total one row when
        # callers select only dimensions/GROUPING without a visible aggregate.
        selected = selected ++ [{:field, {:count, "*"}, "selecto_rollup_internal_count"}]

        branch_set =
          selecto.set
          |> Map.put(:selected, selected)
          |> Map.put(:group_by, retained)
          |> Map.put(:active_joins, joins)
          |> Map.put(:order_by, [])
          |> Map.put(:limit, nil)
          |> Map.put(:offset, nil)

        branch = %{selecto | set: branch_set}
        branch_opts = Keyword.put(opts, :unique_projection_aliases, true)
        {iodata, _, branch_joins} = Sql.build_iodata_with_joins(branch, branch_opts)

        {["SELECT * FROM (", iodata, ")"], Enum.uniq(joins_acc ++ List.wrap(branch_joins))}
      end)

    projection =
      aliases
      |> Enum.with_index(1)
      |> Enum.map(fn {name, index} ->
        output =
          if Keyword.get(opts, :unique_projection_aliases, false),
            do: Sql.projection_alias(index),
            else: name

        [
          Adapter.quote_identifier(Sql.projection_alias(index)),
          " AS ",
          Adapter.quote_identifier(output)
        ]
      end)

    sql = [
      "SELECT ",
      Enum.intersperse(projection, ", "),
      " FROM (",
      Enum.intersperse(branches, " UNION ALL "),
      ") AS selecto_rollup",
      order,
      pagination!(selecto.set)
    ]

    {sql, aliases, resolved_joins}
  end

  # The dimensions and the grouping sets (positions into them), in the order
  # their branches are unioned.
  defp grouping!(:rollup, rollup: dimensions) when is_list(dimensions) do
    validate_dimensions!(dimensions, @max_dimensions)
    %{dimensions: dimensions, sets: sets} = Selecto.GroupingSets.positions(rollup: dimensions)
    {dimensions, sets}
  end

  defp grouping!(:rollup, _), do: unsupported!("ROLLUP must be the only grouping specification")

  defp grouping!(mode, [{mode, _}] = group_by) when mode in [:cube, :grouping_sets] do
    %{dimensions: dimensions, sets: sets} = Selecto.GroupingSets.positions(group_by)
    limit = if mode == :cube, do: @max_dimensions, else: @max_set_dimensions
    validate_dimensions!(dimensions, limit)
    {dimensions, sets}
  end

  defp grouping!(_mode, _),
    do: unsupported!("CUBE or GROUPING SETS must be the only grouping specification")

  defp validate_dimensions!(dimensions, limit) do
    fields = Enum.map(dimensions, &field/1)

    unless fields != [] and length(fields) <= limit and
             Enum.all?(fields, &is_binary/1) and length(Enum.uniq(fields)) == length(fields) do
      unsupported!("one to #{limit} distinct field dimensions are required")
    end
  end

  defp validate_shape!(selecto, selectors) do
    unless selectors != [] and length(selectors) <= @max_selectors do
      unsupported!("one to sixty-four output selectors are required")
    end

    for key <- [
          :window_functions,
          :json_selects,
          :array_operations,
          :subselects,
          :json_order_by,
          :having
        ] do
      unless Map.get(selecto.set, key, []) in [nil, [], %{}] do
        unsupported!("#{key} cannot be combined with bounded SQLite grouping sets")
      end
    end
  end

  defp validate_selector!({:field, selector, _name}, dimensions),
    do: validate_selector!(selector, dimensions)

  defp validate_selector!({:field, selector}, dimensions),
    do: validate_selector!(selector, dimensions)

  defp validate_selector!({:grouping, arguments}, dimensions) when is_list(arguments) do
    arguments = Enum.map(arguments, &field/1)
    fields = Enum.map(dimensions, &field/1)

    unless arguments != [] and length(Enum.uniq(arguments)) == length(arguments) and
             Enum.all?(arguments, &(&1 in fields)) do
      unsupported!("GROUPING arguments must be distinct grouping dimensions")
    end
  end

  defp validate_selector!({:coalesce, arguments}, dimensions)
       when is_list(arguments) and arguments != [] do
    Enum.each(arguments, &validate_selector!(&1, dimensions))
    unless Enum.any?(arguments, &aggregate?/1), do: unsupported!("COALESCE requires an aggregate")
  end

  defp validate_selector!(selector, dimensions) do
    cond do
      field(selector) in Enum.map(dimensions, &field/1) ->
        :ok

      aggregate?(selector) and not contains_grouping?(selector) ->
        :ok

      literal?(selector) ->
        :ok

      true ->
        unsupported!("output selectors must be dimensions, aggregates, literals, or GROUPING")
    end
  end

  # `retained` are the dimensions a branch groups by.
  defp rewrite({:field, selector, _alias}, dimensions, retained),
    do: rewrite(selector, dimensions, retained)

  defp rewrite({:field, selector}, dimensions, retained),
    do: rewrite(selector, dimensions, retained)

  defp rewrite({:grouping, arguments}, _dimensions, retained) do
    retained = Enum.map(retained, &field/1)

    mask =
      Enum.reduce(arguments, 0, fn argument, mask ->
        mask * 2 + if(field(argument) in retained, do: 0, else: 1)
      end)

    {:literal, mask}
  end

  defp rewrite({:coalesce, arguments}, dimensions, retained),
    do: {:coalesce, Enum.map(arguments, &rewrite(&1, dimensions, retained))}

  defp rewrite(selector, dimensions, retained) do
    if field(selector) in Enum.map(dimensions, &field/1) and
         field(selector) not in Enum.map(retained, &field/1),
       do: {:literal, nil},
       else: selector
  end

  defp aggregate?({:count}), do: true
  defp aggregate?({:count, _}), do: true
  defp aggregate?({:count_distinct, _}), do: true
  defp aggregate?({name, _}) when name in [:sum, :avg, :min, :max], do: true
  defp aggregate?({:func, name, [_]}), do: String.upcase(to_string(name)) in @aggregate_functions

  defp aggregate?({:func, name, [_], opts}) when is_list(opts),
    do:
      String.upcase(to_string(name)) in @aggregate_functions and Keyword.keyword?(opts) and
        Enum.all?(opts, fn {key, _} -> key in [:as, :distinct] end)

  defp aggregate?({:coalesce, arguments}), do: Enum.any?(arguments, &aggregate?/1)
  defp aggregate?({:field, expression, _}), do: aggregate?(expression)
  defp aggregate?(_), do: false

  defp literal?({kind, value}) when kind in [:literal, :param],
    do: is_nil(value) or is_binary(value) or is_number(value) or is_boolean(value)

  defp literal?(value), do: is_number(value) or is_boolean(value)

  defp field(value) when is_binary(value), do: value
  defp field(value) when is_atom(value), do: Atom.to_string(value)
  defp field({:field, value}), do: field(value)
  defp field(_), do: nil

  defp contains_grouping?({:grouping, _}), do: true

  defp contains_grouping?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&contains_grouping?/1)

  defp contains_grouping?(value) when is_list(value), do: Enum.any?(value, &contains_grouping?/1)
  defp contains_grouping?(_), do: false

  defp validate_aliases!(aliases) do
    unless Enum.all?(aliases, &(is_binary(&1) and &1 != "")) and
             length(Enum.uniq_by(aliases, &String.downcase/1)) == length(aliases) do
      unsupported!("grouping output aliases must be unique")
    end
  end

  defp outer_order!(orders, selectors, aliases) do
    clauses =
      Enum.map(orders, fn order ->
        {selector, direction} =
          case order do
            {direction, selector} when direction in @directions -> {selector, direction}
            {selector, direction} when direction in @directions -> {selector, direction}
            selector -> {selector, :asc_nulls_first}
          end

        position =
          case selector do
            {:literal_position, position}
            when is_integer(position) and position > 0 and position <= length(selectors) ->
              position

            _ ->
              index =
                Enum.find_index(Enum.zip(selectors, aliases), fn {selected, alias_name} ->
                  selector == selected or selector == unalias(selected) or
                    (is_binary(selector) and
                       String.downcase(selector) == String.downcase(alias_name))
                end)

              if is_nil(index),
                do: unsupported!("final sorting must reference a selected output"),
                else: index + 1
          end

        column = Adapter.quote_identifier(Sql.projection_alias(position))

        case direction do
          :asc ->
            [column, " ASC"]

          :desc ->
            [column, " DESC"]

          :asc_nulls_first ->
            [column, " ASC"]

          :desc_nulls_last ->
            [column, " DESC"]

          :asc_nulls_last ->
            ["CASE WHEN ", column, " IS NULL THEN 1 ELSE 0 END ASC, ", column, " ASC"]

          :desc_nulls_first ->
            ["CASE WHEN ", column, " IS NULL THEN 0 ELSE 1 END ASC, ", column, " DESC"]
        end
      end)

    if clauses == [], do: [], else: [" ORDER BY ", Enum.intersperse(clauses, ", ")]
  end

  defp unalias({:field, expression, _}), do: expression
  defp unalias(expression), do: expression

  defp pagination!(set) do
    limit = Map.get(set, :limit)
    offset = Map.get(set, :offset)

    unless (is_nil(limit) or (is_integer(limit) and limit >= 0)) and
             (is_nil(offset) or (is_integer(offset) and offset >= 0)) do
      unsupported!("pagination requires nonnegative integer limits and offsets")
    end

    [
      if(is_nil(limit),
        do: if(is_nil(offset), do: [], else: " LIMIT -1"),
        else: [" LIMIT ", {:param, limit}]
      ),
      if(is_nil(offset), do: [], else: [" OFFSET ", {:param, offset}])
    ]
  end

  # A shape the emulation cannot express; render/2 refuses it for the mode.
  defp unsupported!(message), do: throw({__MODULE__, :unsupported, message})

  defp refuse!(feature, message) do
    error =
      Selecto.Error.validation_error("Unsupported SQLite #{feature}: " <> message, %{
        adapter: :sqlite,
        unsupported_feature: feature
      })

    # Refused typed through every execute entry point.
    Selecto.Builder.ScopeRefusal.unsupported!(error)
  end
end
