defmodule SelectoDBSQLite.PreparedWriteSafety do
  @moduledoc false
  alias Selecto.Write.{Batch, Command, Error, Graph}
  alias SelectoDBSQLite.{Adapter, WriteCompiler}

  @max_tables 1024
  @max_foreign_keys 4096

  # The final prepared commands include normalizer-added assignments. SQLite
  # automatic FK actions would mutate rows outside this approved write plan.
  def validate(connection, write, opts) do
    commands = commands(write)

    mutations =
      Enum.filter(
        commands,
        &(&1.operation == :delete or
            (&1.operation in [:update, :upsert] and written_fields(&1) != []))
      )

    if mutations == [] do
      :ok
    else
      with {:ok, targets} <- targets(connection, mutations, opts),
           {:ok, changed_tables} <- changed_tables(commands),
           {:ok, %{rows: tables}} <-
             Adapter.execute(
               connection,
               "SELECT name FROM main.sqlite_master WHERE type='table' LIMIT ?",
               [@max_tables + 1],
               opts
             ),
           true <- length(tables) <= @max_tables do
        Enum.reduce_while(tables, {:ok, 0}, fn [table], {:ok, used} ->
          with {:ok, %{rows: keys}} <-
                 Adapter.execute(
                   connection,
                   ~s|SELECT id,seq,"table","from","to",on_update,on_delete FROM pragma_foreign_key_list(?, 'main') LIMIT ?|,
                   [table, @max_foreign_keys + 1],
                   opts
                 ),
               true <- used + length(keys) <= @max_foreign_keys,
               true <- Enum.all?(keys, &safe_key?(&1, targets)),
               true <- safe_deletes?(connection, table, keys, targets, changed_tables, opts) do
            {:cont, {:ok, used + length(keys)}}
          else
            _ -> {:halt, pending()}
          end
        end)
        |> case do
          {:ok, _used} -> :ok
          error -> error
        end
      else
        _ -> pending()
      end
    end
  rescue
    _ -> pending()
  end

  defp commands(%Command{} = command), do: [command]
  defp commands(%Batch{commands: commands}), do: commands

  defp commands(%Graph{nodes: nodes}),
    do:
      Enum.flat_map(nodes, fn node ->
        rows = Enum.map(node.rows, & &1.command)

        if node.delete_missing?,
          do: rows ++ [%Command{operation: :delete, relation: node.relation}],
          else: rows
      end)

  defp changed_tables(commands) do
    commands
    |> Enum.filter(&(&1.operation in [:insert, :update, :upsert]))
    |> Enum.reduce_while({:ok, MapSet.new()}, fn command, {:ok, tables} ->
      case main_table(command.relation) do
        {:ok, table} -> {:cont, {:ok, MapSet.put(tables, ascii_fold(table))}}
        _ -> {:halt, pending()}
      end
    end)
  end

  defp targets(connection, commands, opts) do
    Enum.reduce_while(commands, {:ok, %{}}, fn command, {:ok, targets} ->
      with {:ok, table} <- main_table(command.relation),
           {:ok, %{rows: []}} <-
             Adapter.execute(
               connection,
               "SELECT name FROM temp.sqlite_master WHERE type IN ('table','view') AND name = ? COLLATE NOCASE LIMIT 1",
               [table],
               opts
             ),
           {:ok, %{rows: primary}} <-
             Adapter.execute(
               connection,
               "SELECT name FROM pragma_table_xinfo(?, 'main') WHERE pk > 0 ORDER BY pk",
               [table],
               opts
             ) do
        key = ascii_fold(table)
        assigned = MapSet.new(written_fields(command), &ascii_fold/1)
        prior = Map.get(targets, key, %{assigned: MapSet.new(), primary: [], deletes: []})

        target = %{
          assigned: MapSet.union(prior.assigned, assigned),
          primary: Enum.map(primary, fn [field] -> field end),
          table: table,
          deletes: prior.deletes ++ if(command.operation == :delete, do: [command], else: [])
        }

        {:cont, {:ok, Map.put(targets, key, target)}}
      else
        _ -> {:halt, pending()}
      end
    end)
  end

  defp written_fields(%Command{operation: :upsert, metadata: metadata}),
    do: Map.fetch!(metadata, :upsert_update_fields)

  defp written_fields(%Command{assignments: assignments}), do: Enum.map(assignments, & &1.field)

  defp safe_key?([_id, _seq, parent, _from, field, action, _delete], targets) do
    case Map.get(targets, ascii_fold(parent)) do
      nil ->
        true

      %{assigned: assigned, primary: primary} ->
        case action do
          action when action in ["NO ACTION", "RESTRICT"] ->
            true

          action when action in ["CASCADE", "SET NULL", "SET DEFAULT"] ->
            referenced = if is_nil(field), do: primary, else: [field]

            referenced != [] and
              Enum.all?(referenced, &(not MapSet.member?(assigned, ascii_fold(&1))))

          _ ->
            false
        end
    end
  end

  defp safe_deletes?(connection, child, keys, targets, changed_tables, opts) do
    keys
    |> Enum.group_by(&hd/1)
    |> Enum.all?(fn {_id, keys} ->
      keys = Enum.sort_by(keys, &Enum.at(&1, 1))
      [_id, _seq, parent, _from, _to, _update, action] = hd(keys)

      case Map.get(targets, ascii_fold(parent)) do
        nil ->
          true

        %{deletes: []} ->
          true

        target ->
          cond do
            action in ["NO ACTION", "RESTRICT"] ->
              true

            action in ["CASCADE", "SET NULL", "SET DEFAULT"] ->
              # A sibling command can make a currently absent reference appear.
              not MapSet.member?(changed_tables, ascii_fold(child)) and
                trigger_free_plan?(connection, targets, changed_tables, opts) and
                Enum.all?(
                  target.deletes,
                  &delete_references_absent?(connection, child, keys, target, &1, opts)
                )

            true ->
              false
          end
      end
    end)
  end

  defp trigger_free_plan?(connection, targets, changed_tables, opts) do
    targets
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.union(changed_tables)
    |> Enum.all?(fn table ->
      sql =
        "SELECT 1 FROM main.sqlite_master WHERE type='trigger' AND tbl_name = ? COLLATE NOCASE UNION ALL SELECT 1 FROM temp.sqlite_master WHERE type='trigger' AND tbl_name = ? COLLATE NOCASE LIMIT 1"

      match?({:ok, %{rows: []}}, Adapter.execute(connection, sql, [table, table], opts))
    end)
  end

  defp delete_references_absent?(connection, child, keys, target, command, opts) do
    pairs =
      Enum.map(keys, fn [_id, seq, _parent, from, to, _update, _delete] ->
        {from, to || Enum.at(target.primary, seq)}
      end)

    with true <- Enum.all?(pairs, fn {from, to} -> is_binary(from) and is_binary(to) end),
         {:ok, predicate} <- delete_scope(command.predicate, opts),
         join <-
           Enum.map_join(pairs, " AND ", fn {from, to} ->
             "p." <> Adapter.quote_identifier(to) <> " = c." <> Adapter.quote_identifier(from)
           end),
         sql <-
           "SELECT 1 FROM main." <>
             Adapter.quote_identifier(child) <>
             " AS c JOIN main." <>
             Adapter.quote_identifier(target.table) <>
             " AS p ON " <> join <> " WHERE (" <> predicate.text <> ") LIMIT 1",
         {:ok, %{rows: []}} <- Adapter.execute(connection, sql, predicate.params, opts) do
      true
    else
      _ -> false
    end
  end

  # Generated cleanup selectors are not yet materialized. Global absence is
  # stronger than any later selected scope and remains valid without child writes.
  defp delete_scope(nil, _opts), do: {:ok, %{text: "1", params: []}}

  defp delete_scope(predicate, opts),
    do:
      WriteCompiler.compile_predicate(
        predicate,
        Keyword.put(opts, :predicate_relation_alias, "p")
      )

  defp main_table(relation) do
    case String.split(to_string(relation), ".") do
      [table] when table != "" -> {:ok, table}
      ["main", table] when table != "" -> {:ok, table}
      _ -> :error
    end
  end

  defp ascii_fold(value),
    do:
      for(<<byte <- to_string(value)>>,
        into: "",
        do: <<if(byte in ?A..?Z, do: byte + 32, else: byte)>>
      )

  defp pending,
    do:
      {:error,
       Error.new(:validation, "automatic foreign-key effects are outside the prepared write plan",
         details: %{code: :native_write_effects_not_evaluable}
       )}
end
