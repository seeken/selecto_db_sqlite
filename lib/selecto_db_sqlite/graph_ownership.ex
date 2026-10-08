defmodule SelectoDBSQLite.GraphOwnership do
  @moduledoc false

  alias Selecto.Write.{Error, Graph}
  alias SelectoDBSQLite.InsertAdmission

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

  def validate(connection, %Graph{nodes: nodes}, opts) do
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
           :ok <- require_comparison(parent, parent_field, child, child_field) do
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

  def validate(_connection, _write, _opts), do: :ok

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
    case Enum.find(schema, fn {name, _column} ->
           ascii_fold(name) == ascii_fold(to_string(field))
         end) do
      {_name, column} -> column
      nil -> nil
    end
  end

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

  defp refusal do
    {:error,
     Error.new(:validation, "SQLite cannot establish equivalent owned-key comparisons",
       details: %{code: :owned_key_comparison_not_evaluable}
     )}
  end
end
