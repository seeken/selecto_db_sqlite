defmodule SelectoDBSQLite.GraphOwnership do
  @moduledoc false

  alias Selecto.Write.{Error, Graph}
  alias SelectoDBSQLite.InsertAdmission
  alias SelectoDBSQLite.Adapter

  # SQLite foreign-key membership uses the parent's affinity and collation.
  # Generated owned-row predicates use the child column. These predicates are
  # equivalent only inside this deliberately finite physical comparator port.
  def require_comparison(parent_schema, parent_field, child_schema, child_field) do
    with %{hidden: 0, collation: collation, declared_type: parent_type} <-
           column(parent_schema, parent_field),
         %{hidden: 0, collation: ^collation, declared_type: child_type} <-
           column(child_schema, child_field),
         true <- collation in ["BINARY", "NOCASE", "RTRIM"],
         true <- is_binary(parent_type) and is_binary(child_type),
         affinity when not is_nil(affinity) <- affinity(parent_type),
         ^affinity <- affinity(child_type) do
      :ok
    else
      _ -> refusal()
    end
  end

  # The comparison alone does not establish a parent identity. A UNIQUE index
  # with a different collation can admit multiple rows that the generated
  # ownership predicate treats as equal; every present FK must also agree with
  # the domain's edge, rather than merely finding one matching constraint.
  def require_physical_edge(
        connection,
        parent_relation,
        parent_field,
        parent_schema,
        child_relation,
        child_field,
        child_schema,
        opts
      ) do
    with :ok <- require_comparison(parent_schema, parent_field, child_schema, child_field),
         {:ok, parent_table} <- table(parent_relation),
         {:ok, child_table} <- table(child_relation),
         {parent_name, parent_column} <- named_column(parent_schema, parent_field),
         {child_name, _child_column} <- named_column(child_schema, child_field),
         {:ok, true} <-
           unique_parent?(
             connection,
             parent_table,
             parent_name,
             parent_column,
             parent_schema,
             opts
           ),
         {:ok, true} <-
           matching_foreign_keys?(
             connection,
             child_table,
             child_name,
             parent_table,
             parent_name,
             parent_schema,
             opts
           ) do
      :ok
    else
      _ -> refusal()
    end
  end

  def validate(connection, %Graph{nodes: nodes, metadata: metadata}, opts) do
    with :ok <- inferred_edges(connection, Map.get(metadata, :catalog_inferred_edges), opts) do
      validate_nodes(connection, nodes, opts)
    end
  end

  def validate(_connection, _write, _opts), do: :ok

  defp inferred_edges(_connection, nil, _opts), do: :ok

  defp inferred_edges(connection, edges, opts) when is_list(edges) and length(edges) in 1..128 do
    Enum.reduce_while(edges, :ok, fn edge, :ok ->
      case SelectoDBSQLite.GraphDomainInference.require_declared_edge(connection, edge, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp inferred_edges(_, _, _), do: refusal()

  defp validate_nodes(connection, nodes, opts) do
    by_id = Map.new(nodes, &{&1.id, &1})

    comparisons =
      Enum.flat_map(nodes, fn node ->
        bindings =
          for row <- node.rows, binding <- row.bindings do
            {node.relation, binding.field, binding.from_node, binding.from_field}
          end

        bindings ++ generated_comparisons(node.sync_predicate, node.relation)
      end)

    comparisons
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn {child_relation, child_field, parent_id, parent_field},
                                        {:ok, schemas} ->
      with %{relation: parent_relation} <- Map.get(by_id, parent_id),
           {:ok, parent, schemas} <- schema(connection, parent_relation, schemas, opts),
           {:ok, child, schemas} <- schema(connection, child_relation, schemas, opts),
           :ok <-
             require_physical_edge(
               connection,
               parent_relation,
               parent_field,
               parent,
               child_relation,
               child_field,
               child,
               opts
             ) do
        {:cont, {:ok, schemas}}
      else
        _ -> {:halt, refusal()}
      end
    end)
    |> case do
      {:ok, _schemas} -> :ok
      error -> error
    end
  end

  defp unique_parent?(connection, table, name, column, schema, opts) do
    with {:ok, %{rows: indexes}} <- pragma(connection, "index_list", table, opts),
         {:ok, unique?} <- matching_unique_index?(connection, indexes, name, column, opts) do
      # INTEGER PRIMARY KEY aliases rowid unless SQLite created a PK index
      # (including the historical DESC form and WITHOUT ROWID tables).
      rowid? =
        Enum.all?(indexes, fn [_seq, _name, _unique, origin, _partial] -> origin != "pk" end) and
          column.declared_type == "INTEGER" and sole_primary_key(schema) == name

      {:ok, unique? or rowid?}
    end
  end

  defp matching_unique_index?(connection, indexes, name, column, opts) do
    Enum.reduce_while(indexes, {:ok, false}, fn
      [_seq, index, 1, _origin, 0], {:ok, false} ->
        case pragma(connection, "index_xinfo", index, opts) do
          {:ok, %{rows: rows}} ->
            keys =
              Enum.filter(rows, fn [_seq, _cid, _field, _desc, _collation, key] -> key == 1 end)

            case keys do
              [[_seq, cid, ^name, _desc, collation, 1]] when cid >= 0 ->
                if ascii_upcase(collation) == column.collation,
                  do: {:halt, {:ok, true}},
                  else: {:cont, {:ok, false}}

              _ ->
                {:cont, {:ok, false}}
            end

          _ ->
            {:halt, refusal()}
        end

      [_seq, _index, _unique, _origin, _partial], result ->
        {:cont, result}
    end)
  end

  defp matching_foreign_keys?(connection, child, child_field, parent, parent_field, schema, opts) do
    with {:ok, %{rows: keys}} <- pragma(connection, "foreign_key_list", child, opts) do
      matching? =
        keys
        |> Enum.group_by(&hd/1)
        |> Enum.all?(fn {_id, entries} ->
          if Enum.any?(entries, fn [_id, _seq, _table, from | _rest] ->
               ascii_fold(from) == ascii_fold(child_field)
             end) do
            case entries do
              [[_id, 0, target, _from, to, _update, _delete, _match]] ->
                referenced = to || sole_primary_key(schema)

                is_binary(referenced) and ascii_fold(target) == ascii_fold(parent) and
                  ascii_fold(referenced) == ascii_fold(parent_field)

              _ ->
                false
            end
          else
            true
          end
        end)

      {:ok, matching?}
    end
  end

  defp sole_primary_key(schema) do
    case Enum.filter(schema, fn {_name, column} -> column.primary_key end) do
      [{name, _column}] -> name
      _ -> nil
    end
  end

  defp pragma(connection, operation, name, opts),
    do:
      Adapter.execute(
        connection,
        "PRAGMA main.#{operation}(#{Adapter.quote_identifier(name)})",
        [],
        opts
      )

  defp generated_comparisons(
         {:eq, {:field, child_field}, {:generated, parent_id, _row, parent_field}},
         relation
       ),
       do: [{relation, child_field, parent_id, parent_field}]

  defp generated_comparisons(
         {:eq, {:generated, parent_id, _row, parent_field}, {:field, child_field}},
         relation
       ),
       do: [{relation, child_field, parent_id, parent_field}]

  defp generated_comparisons({kind, predicates}, relation)
       when kind in [:and, :or] and is_list(predicates),
       do: Enum.flat_map(predicates, &generated_comparisons(&1, relation))

  defp generated_comparisons({:not, predicate}, relation),
    do: generated_comparisons(predicate, relation)

  defp generated_comparisons(_predicate, _relation), do: []

  defp schema(connection, relation, schemas, opts) do
    with {:ok, table} <- table(relation) do
      case Map.fetch(schemas, ascii_fold(table)) do
        {:ok, schema} ->
          {:ok, schema, schemas}

        :error ->
          with {:ok, schema} <- InsertAdmission.storage_schema(connection, table, opts) do
            {:ok, schema, Map.put(schemas, ascii_fold(table), schema)}
          end
      end
    end
  end

  defp table(relation) do
    case String.split(to_string(relation), ".") do
      [name] when name != "" -> {:ok, name}
      ["main", name] when name != "" -> {:ok, name}
      _ -> refusal()
    end
  end

  defp column(schema, field) do
    case named_column(schema, field) do
      {_name, column} -> column
      nil -> nil
    end
  end

  defp named_column(schema, field),
    do:
      Enum.find(schema, fn {name, _column} ->
        ascii_fold(name) == ascii_fold(to_string(field))
      end)

  # In a STRICT table, ANY differs from ordinary ANY's NUMERIC affinity. This
  # port refuses ANY rather than assuming which table storage semantics apply.
  defp affinity("ANY"), do: nil

  defp affinity(declaration) do
    cond do
      String.contains?(declaration, "INT") -> :integer
      String.contains?(declaration, ["CHAR", "CLOB", "TEXT"]) -> :text
      declaration == "" or String.contains?(declaration, "BLOB") -> :blob
      String.contains?(declaration, ["REAL", "FLOA", "DOUB"]) -> :real
      true -> :numeric
    end
  end

  defp ascii_fold(value) do
    for <<byte <- value>>,
      into: <<>>,
      do: <<if(byte in ?A..?Z, do: byte + 32, else: byte)>>
  end

  defp ascii_upcase(value) do
    for <<byte <- value>>,
      into: <<>>,
      do: <<if(byte in ?a..?z, do: byte - 32, else: byte)>>
  end

  defp refusal do
    {:error,
     Error.new(:validation, "SQLite cannot establish equivalent owned-key comparisons",
       details: %{code: :owned_key_comparison_not_evaluable}
     )}
  end
end
