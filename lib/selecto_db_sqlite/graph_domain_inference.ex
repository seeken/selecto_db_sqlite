defmodule SelectoDBSQLite.GraphDomainInference do
  @moduledoc false
  alias Selecto.Domain.Contract.Shared.Core
  alias Selecto.Write.Error
  alias SelectoDBSQLite.{Adapter, GraphOwnership, InsertAdmission, Introspection}

  # Creation-only imports can establish composition without granting cleanup,
  # update or deletion. Each inferred edge must exist physically and point to a
  # unique parent. The same facts are rechecked before native graph dispatch.
  def infer(connection, domain, opts) do
    with {:ok, %{rows: [[1]]}} <- Adapter.execute(connection, "PRAGMA foreign_keys", [], opts),
         {:ok, inferred, edges, _count} <- domain(connection, domain, opts, 0, 0) do
      {:ok, %{domain: inferred, edges: edges}}
    else
      _ -> refusal()
    end
  end

  def require_declared_edge(connection, {child, child_key, parent, parent_key}, opts) do
    with {:ok, %{rows: [[1]]}} <- Adapter.execute(connection, "PRAGMA foreign_keys", [], opts),
         {:ok, parent_schema} <- InsertAdmission.storage_schema(connection, parent, opts),
         {:ok, child_schema} <- InsertAdmission.storage_schema(connection, child, opts),
         :ok <-
           GraphOwnership.require_physical_edge(
             connection,
             parent,
             parent_key,
             parent_schema,
             child,
             child_key,
             child_schema,
             opts
           ),
         {:ok, metadata} <-
           Introspection.introspect_table(connection, child, Keyword.put(opts, :schema, "main")),
         %{nullable: false, generated: false} <- Map.get(metadata.columns, child_key),
         keys <- Enum.filter(metadata.foreign_keys, &(&1.column_name == child_key)),
         [key] <- keys,
         true <- key.sequence == 0 and key.foreign_table_name == parent,
         true <-
           key.foreign_column_name == parent_key or
             (is_nil(key.foreign_column_name) and sole_key(parent_schema) == parent_key),
         true <- Enum.count(metadata.foreign_keys, &(&1.id == key.id)) == 1 do
      :ok
    else
      _ -> refusal()
    end
  end

  def require_declared_edge(_, _, _), do: refusal()

  defp domain(_connection, _domain, _opts, depth, count) when depth >= 32 or count >= 128,
    do: refusal()

  defp domain(connection, domain, opts, depth, count) when is_map(domain) do
    source = Core.map_value(domain, :source)
    writes = Core.map_value(domain, :writes)
    relationships = Core.map_value(writes, :relationships) || %{}

    with true <- is_map(source) and is_map(writes) and is_map(relationships),
         true <-
           Core.map_value(Core.map_value(Core.map_value(writes, :operations), :insert), :enabled) ==
             true,
         parent when is_binary(parent) <- Core.map_value(source, :source_table),
         true <- identifier?(parent),
         {:ok, relationships, edges, count} <-
           Enum.reduce_while(relationships, {:ok, %{}, [], count + 1}, fn {name, spec},
                                                                          {:ok, declared, edges,
                                                                           count} ->
             with true <- is_map(spec) and Core.map_value(spec, :writable) == true,
                  allowed when is_list(allowed) <- Core.map_value(spec, :allowed_ops),
                  true <- allowed in [["insert"], [:insert]],
                  child_domain when is_map(child_domain) <- Core.map_value(spec, :domain),
                  child_source when is_map(child_source) <- Core.map_value(child_domain, :source),
                  child when is_binary(child) <- Core.map_value(child_source, :source_table),
                  true <- identifier?(child),
                  parent_key <- name(Core.map_value(spec, :parent_key)),
                  child_key <- name(Core.map_value(spec, :child_key)),
                  true <- identifier?(parent_key) and identifier?(child_key),
                  edge = {child, child_key, parent, parent_key},
                  :ok <- require_declared_edge(connection, edge, opts),
                  {:ok, metadata} <-
                    Introspection.introspect_table(
                      connection,
                      child,
                      Keyword.put(opts, :schema, "main")
                    ),
                  cardinality = if(unique_child?(metadata, child_key), do: :one, else: :many),
                  true <-
                    Core.map_value(spec, :cardinality) in [
                      nil,
                      cardinality,
                      to_string(cardinality)
                    ],
                  true <-
                    Core.map_value(spec, :ownership) in [
                      nil,
                      :owned,
                      "owned",
                      :composition,
                      "composition"
                    ],
                  {:ok, child_domain, child_edges, count} <-
                    domain(connection, child_domain, opts, depth + 1, count) do
               spec =
                 spec
                 |> Map.put(:domain, child_domain)
                 |> Map.put(:cardinality, cardinality)
                 |> Map.put(:ownership, :composition)

               {:cont,
                {:ok, Map.put(declared, name, spec), edges ++ [edge] ++ child_edges, count}}
             else
               _ -> {:halt, refusal()}
             end
           end) do
      {:ok, Map.put(domain, :writes, Map.put(writes, :relationships, relationships)), edges,
       count}
    else
      _ -> refusal()
    end
  end

  defp domain(_, _, _, _, _), do: refusal()

  defp sole_key(schema) do
    case Enum.filter(schema, fn {_name, column} -> column.primary_key end) do
      [{name, _}] -> name
      _ -> nil
    end
  end

  defp unique_child?(metadata, field) do
    name(metadata.primary_key) == field or
      Enum.any?(metadata.indexes, fn index ->
        index.unique and not index.partial and
          match?([%{column: ^field, expression: false}], index.columns)
      end)
  end

  defp name(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp name(value) when is_binary(value), do: value
  defp name(_), do: nil

  defp identifier?(name) when is_binary(name),
    do: Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name)

  defp identifier?(_), do: false

  defp refusal,
    do:
      {:error,
       Error.new(:validation, "SQLite cannot prove creation-only graph relationship inference",
         details: %{code: :owned_key_comparison_not_evaluable}
       )}
end
