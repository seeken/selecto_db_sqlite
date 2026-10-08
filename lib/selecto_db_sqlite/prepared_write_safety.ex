defmodule SelectoDBSQLite.PreparedWriteSafety do
  @moduledoc false
  alias Selecto.Write.{Batch, Command, Error, Graph}
  alias SelectoDBSQLite.Adapter

  @max_tables 1024
  @max_foreign_keys 4096

  # The final prepared commands include normalizer-added assignments. SQLite
  # automatic FK actions would mutate rows outside this approved write plan.
  def validate(connection, write, opts) do
    updates =
      write
      |> commands()
      |> Enum.filter(&(&1.operation in [:update, :upsert] and written_fields(&1) != []))

    if updates == [] do
      :ok
    else
      with {:ok, targets} <- targets(connection, updates, opts),
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
                   ~s|SELECT "table","to",on_update FROM pragma_foreign_key_list(?, 'main') LIMIT ?|,
                   [table, @max_foreign_keys + 1],
                   opts
                 ),
               true <- used + length(keys) <= @max_foreign_keys,
               true <- Enum.all?(keys, &safe_key?(&1, targets)) do
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
    do: Enum.flat_map(nodes, &Enum.map(&1.rows, fn row -> row.command end))

  defp targets(connection, commands, opts) do
    Enum.reduce_while(commands, {:ok, %{}}, fn command, {:ok, targets} ->
      with {:ok, table} <- main_table(command.relation),
           {:ok, %{rows: primary}} <-
             Adapter.execute(
               connection,
               "SELECT name FROM pragma_table_xinfo(?, 'main') WHERE pk > 0 ORDER BY pk",
               [table],
               opts
             ) do
        key = ascii_fold(table)
        assigned = MapSet.new(written_fields(command), &ascii_fold/1)
        prior = Map.get(targets, key, %{assigned: MapSet.new(), primary: []})

        target = %{
          assigned: MapSet.union(prior.assigned, assigned),
          primary: Enum.map(primary, fn [field] -> ascii_fold(field) end)
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

  defp safe_key?([parent, field, action], targets) do
    case Map.get(targets, ascii_fold(parent)) do
      nil ->
        true

      %{assigned: assigned, primary: primary} ->
        case action do
          action when action in ["NO ACTION", "RESTRICT"] ->
            true

          action when action in ["CASCADE", "SET NULL", "SET DEFAULT"] ->
            referenced = if is_nil(field), do: primary, else: [ascii_fold(field)]
            referenced != [] and Enum.all?(referenced, &(not MapSet.member?(assigned, &1)))

          _ ->
            false
        end
    end
  end

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
