defmodule SelectoDBSQLite.UpsertCandidate do
  @moduledoc false

  alias Selecto.Write.{Batch, Command, Error, Graph, RuleCandidateRequest}
  alias Selecto.Write.{UpsertCandidateRequest, UpsertCandidateState}
  alias SelectoDBSQLite.{Adapter, InsertAdmission, QueryGuard, RuleCandidate, WriteCompiler}

  @registry {__MODULE__, :receipts}
  @receipt_keys [:protected_upsert_receipt, :protected_upsert_subject]
  @max_columns 512
  @max_indexes 256
  @max_subjects 1024
  @max_bytes 1_048_576

  # Receipts live in the adapter's prepared-write tracker, which is destroyed
  # at transaction exit. Neither a command's metadata nor a caller's supplied
  # prior-state value can create one.
  def project(connection, %UpsertCandidateRequest{} = request, opts) do
    opts = Keyword.put(opts, :upsert_relation, request.command.relation)

    with {:ok, tracker} <- tracker(opts),
         :ok <- Adapter.require_committed_reads(connection, opts),
         :ok <- valid_request(request),
         {:ok, previous} <- prior(request, tracker),
         {:ok, facts} <- schema_facts(connection, request, opts),
         {:ok, submitted} <- submitted_values(request.command, request.context, facts.schema),
         {:ok, inserted} <- project_insert(connection, request, facts, submitted, opts),
         {:ok, selection} <- select_branch(connection, facts, inserted, opts),
         :ok <- same_selection(previous, selection),
         {:ok, values, prior_values, effect} <-
           candidate(connection, request, facts, inserted, selection, opts),
         {:ok, receipt} <-
           register(connection, request, facts, selection, values, inserted, effect, tracker) do
      {:ok,
       %UpsertCandidateState{
         values: values,
         prior_values: prior_values,
         branch: selection.branch,
         effect: effect,
         complete?: true,
         protection: :locked,
         receipt: receipt
       }}
    else
      {:error, %Error{}} = error -> error
      _ -> pending()
    end
  rescue
    _ -> pending()
  end

  @doc false
  def prospective(connection, command, types, dependencies, context, opts) do
    request = %UpsertCandidateRequest{
      command: command,
      field_types: types,
      dependencies: dependencies,
      context: context,
      subject: make_ref()
    }

    opts = Keyword.put(opts, :upsert_relation, command.relation)

    with :ok <- valid_request(request),
         {:ok, facts} <- schema_facts(connection, request, opts),
         {:ok, submitted} <- submitted_values(command, context, facts.schema),
         {:ok, inserted} <- project_insert(connection, request, facts, submitted, opts),
         {:ok, selection} <- select_branch(connection, facts, inserted, opts),
         {:ok, values, _prior_values, effect} <-
           candidate(connection, request, facts, inserted, selection, opts) do
      {:ok,
       Map.merge(facts, selection)
       |> Map.merge(%{values: values, inserted: inserted, effect: effect})}
    else
      _ -> pending()
    end
  rescue
    _ -> pending()
  end

  @doc false
  def project_values(connection, operation, relation, values, types, dependencies, context, opts),
    do:
      project_values(
        connection,
        operation,
        values,
        types,
        dependencies,
        context,
        Keyword.put(opts, :upsert_relation, relation)
      )

  @doc false
  def keys_equal(connection, %{fields: fields}, left, right, opts),
    do: equal_keys(connection, fields, left, right, opts)

  # All receipts and all dependencies are checked before the first mutation.
  # A second check at dispatch binds a materialized graph command as well.
  def validate(connection, write, opts) do
    commands = commands(write)

    with true <- is_list(commands) and length(commands) <= @max_subjects,
         {:ok, entries} <- receipt_entries(connection, commands, opts),
         :ok <- cleanup_dependencies(write, entries),
         :ok <- dependencies(connection, commands, entries, opts) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _ -> pending()
    end
  rescue
    _ -> pending()
  end

  def validate_command(connection, %Command{} = command, opts) do
    case Map.get(command.metadata, :protected_upsert_receipt) do
      nil ->
        if requires_receipt?(command), do: pending(), else: :ok

      _ ->
        with {:ok, [_entry]} <- receipt_entries(connection, [command], opts), do: :ok
    end
  end

  defp valid_request(request) do
    command = request.command

    with true <-
           request.format == "selecto.upsert_candidate_request" and request.format_version == 1,
         %Command{operation: :upsert, predicate: nil} <- command,
         :ok <- Command.validate(command),
         true <- is_reference(request.subject) and is_map(request.context),
         true <- is_map(request.field_types) and map_size(request.field_types) in 1..@max_columns,
         true <- request.dependencies == :all or is_list(request.dependencies),
         true <- :erlang.external_size(request) <= @max_bytes,
         true <- length(command.assignments) in 1..@max_columns,
         fields when is_list(fields) <- Map.get(command.metadata, :upsert_update_fields),
         true <- length(fields) <= @max_columns,
         {:ok, _} <- WriteCompiler.compile(command, context: request.context) do
      :ok
    else
      _ -> pending()
    end
  end

  defp tracker(opts) do
    case Keyword.get(opts, :protected_candidate_tracker) do
      tracker when is_reference(tracker) -> {:ok, tracker}
      _ -> pending()
    end
  end

  defp registry(tracker),
    do: Process.get(tracker, %{}) |> Map.get(@registry, %{receipts: %{}, subjects: %{}})

  defp prior(request, tracker) do
    registry = registry(tracker)

    case {request.prior, Map.get(registry.subjects, request.subject)} do
      {nil, nil} ->
        {:ok, nil}

      {receipt, receipt} when is_reference(receipt) ->
        case Map.fetch(registry.receipts, receipt) do
          {:ok, %{subject: subject, context: context} = entry}
          when subject == request.subject and context === request.context ->
            {:ok, entry}

          _ ->
            pending()
        end

      _ ->
        pending()
    end
  end

  defp schema_facts(connection, request, opts) do
    QueryGuard.run(connection, fn ->
      with {:ok, table} <- main_table(request.command.relation),
           {:ok, schema} <- InsertAdmission.storage_schema(connection, table, opts, :upsert),
           true <- map_size(schema) in 1..@max_columns,
           {:ok, types} <- canonical_map(request.field_types, schema),
           true <- types == canonical_types(request.command.metadata, schema),
           {:ok, target} <-
             canonical_fields(Map.get(request.command.metadata, :conflict_target), schema),
           true <- target != [],
           {:ok, mask} <-
             canonical_fields(Map.get(request.command.metadata, :upsert_update_fields), schema),
           {:ok, arbiter} <- find_arbiter(connection, table, schema, target, opts),
           {:ok, dependencies} <- canonical_dependencies(request.dependencies, types, schema),
           {:ok, witness} <- physical_witness(schema),
           {:ok, %{rows: [[schema_version]]}} <-
             Adapter.execute(connection, "PRAGMA main.schema_version", [], opts) do
        {:ok,
         %{
           table: table,
           schema: schema,
           types: types,
           target: Enum.map(arbiter.fields, &elem(&1, 0)),
           mask: mask,
           arbiter: arbiter,
           witness: witness,
           dependencies: dependencies,
           schema_version: schema_version
         }}
      else
        _ -> pending()
      end
    end)
  end

  defp canonical_dependencies(:all, types, _schema), do: {:ok, Map.keys(types)}
  defp canonical_dependencies(fields, _types, schema), do: canonical_fields(fields, schema)

  defp canonical_types(metadata, schema) do
    case canonical_map(Map.get(metadata, :field_types, %{}), schema) do
      {:ok, types} -> types
      _ -> :invalid
    end
  end

  defp canonical_map(map, schema) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {field, value}, {:ok, result} ->
      with {:ok, field} <- canonical_field(field, schema),
           false <- Map.has_key?(result, field),
           true <- (is_atom(value) and not is_nil(value)) or is_binary(value) do
        {:cont, {:ok, Map.put(result, field, value)}}
      else
        _ -> {:halt, pending()}
      end
    end)
  end

  defp canonical_map(_, _), do: pending()

  defp canonical_fields(fields, schema) when is_list(fields) and length(fields) <= @max_columns do
    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, result} ->
      with {:ok, field} <- canonical_field(field, schema),
           false <- field in result do
        {:cont, {:ok, result ++ [field]}}
      else
        _ -> {:halt, pending()}
      end
    end)
  end

  defp canonical_fields(_, _), do: pending()

  defp canonical_field(field, schema) when is_atom(field) and not is_nil(field),
    do: canonical_field(Atom.to_string(field), schema)

  defp canonical_field(field, schema) when is_binary(field) and byte_size(field) <= 1024 do
    case Enum.filter(Map.keys(schema), &(fold(&1) == fold(field))) do
      [actual] -> {:ok, actual}
      _ -> pending()
    end
  end

  defp canonical_field(_, _), do: pending()

  defp main_table(relation) when is_atom(relation) and not is_nil(relation),
    do: main_table(Atom.to_string(relation))

  defp main_table(relation) when is_binary(relation) and byte_size(relation) <= 2048 do
    case String.split(relation, ".") do
      [table] when table != "" -> {:ok, table}
      ["main", table] when table != "" -> {:ok, table}
      _ -> pending()
    end
  end

  defp main_table(_), do: pending()

  defp arbiter(_connection, _table, schema, [field], _opts)
       when is_map_key(schema, field) do
    if schema[field].rowid_alias,
      do: {:ok, %{kind: :rowid, fields: [{field, "BINARY"}]}},
      else: :indexes
  end

  defp arbiter(_connection, _table, _schema, _target, _opts), do: :indexes

  defp find_arbiter(connection, table, schema, target, opts) do
    case arbiter(connection, table, schema, target, opts) do
      :indexes -> index_arbiters(connection, table, schema, target, opts)
      result -> result
    end
  end

  # The internal order of SQLite's Index linked list is not a public PRAGMA
  # contract. Admit multiple matches only if they express the same comparison.
  defp index_arbiters(connection, table, schema, target, opts) do
    with {:ok, %{rows: rows}} <-
           Adapter.execute(connection, "PRAGMA main.index_list(#{q(table)})", [], opts),
         true <- length(rows) <= @max_indexes,
         {:ok, matches} <-
           Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, matches} ->
             case row do
               [_seq, name, 1, _origin, 0] when is_binary(name) ->
                 case index_fields(connection, name, schema, opts) do
                   {:ok, fields} ->
                     if length(fields) == length(target) and
                          MapSet.new(Enum.map(fields, &elem(&1, 0))) == MapSet.new(target),
                        do: {:cont, {:ok, [Enum.sort(fields) | matches]}},
                        else: {:cont, {:ok, matches}}

                   :unsupported ->
                     {:cont, {:ok, matches}}

                   _ ->
                     {:halt, pending()}
                 end

               [_seq, name, unique, origin, partial]
               when is_binary(name) and unique in [0, 1] and is_binary(origin) and
                      partial in [0, 1] ->
                 {:cont, {:ok, matches}}

               _ ->
                 {:halt, pending()}
             end
           end),
         [fields] <- Enum.uniq(matches),
         true <- length(fields) == length(target),
         true <- Enum.all?(fields, fn {_field, coll} -> coll in ["BINARY", "NOCASE", "RTRIM"] end) do
      {:ok, %{kind: :index, fields: fields}}
    else
      _ -> pending()
    end
  end

  defp index_fields(connection, name, schema, opts) do
    with true <- byte_size(name) <= 1024,
         {:ok, %{rows: rows}} <-
           Adapter.execute(connection, "PRAGMA main.index_xinfo(#{q(name)})", [], opts),
         true <- length(rows) in 1..(@max_columns + 1),
         true <- Enum.all?(rows, &match?([_, _, _, _, _, _], &1)) do
      rows
      |> Enum.filter(fn [_, _, _, _, _, key] -> key == 1 end)
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, fields} ->
        case row do
          [_seq, cid, field, desc, coll, 1]
          when is_integer(cid) and cid >= 0 and is_binary(field) and desc in [0, 1] and
                 is_binary(coll) ->
            if Map.has_key?(schema, field),
              do: {:cont, {:ok, fields ++ [{field, ascii_upcase(coll)}]}},
              else: {:halt, pending()}

          [_seq, -2, _, _, _, 1] ->
            {:halt, :unsupported}

          _ ->
            {:halt, pending()}
        end
      end)
    else
      _ -> pending()
    end
  end

  defp physical_witness(schema) do
    if Enum.all?(schema, fn {_field, column} -> column.without_rowid == 1 end) do
      fields = for {field, %{primary_key: true}} <- schema, do: field
      if fields == [], do: pending(), else: {:ok, Enum.sort(fields)}
    else
      names = MapSet.new(Map.keys(schema), &fold/1)

      case Enum.find(["rowid", "_rowid_", "oid"], &(not MapSet.member?(names, &1))) do
        nil -> pending()
        field -> {:ok, [field]}
      end
    end
  end

  defp submitted_values(command, context, schema) do
    Enum.reduce_while(command.assignments, {:ok, %{}}, fn assignment, {:ok, values} ->
      with {:ok, field} <- canonical_field(assignment.field, schema),
           false <- Map.has_key?(values, field),
           {:ok, value} <- literal(assignment.value, context) do
        {:cont, {:ok, Map.put(values, field, value)}}
      else
        _ -> {:halt, pending()}
      end
    end)
  end

  defp literal({:literal, value}, _context), do: {:ok, value}
  defp literal({:context, key}, context), do: Map.fetch(context, key)
  defp literal(_, _), do: pending()

  defp project_insert(connection, request, facts, submitted, opts) do
    # Missing or NULL rowid means actual generated identity, never a guessed
    # rowid. Only an unconsumed generated identity can proceed.
    keys =
      Enum.reject(
        facts.target,
        &(facts.schema[&1].rowid_alias and is_nil(Map.get(submitted, &1)))
      )

    project_values(connection, :insert, submitted, facts.types, keys, request.context, opts)
  end

  defp select_branch(connection, facts, inserted, opts) do
    with arbiter <- facts.arbiter do
      keys = Enum.map(arbiter.fields, fn {field, _} -> Map.get(inserted, field) end)

      if Enum.any?(keys, &is_nil/1) do
        {:ok, %{branch: :insert, physical_id: nil, prior: %{}, arbiter: arbiter, keys: keys}}
      else
        QueryGuard.run(connection, fn ->
          fields = Map.keys(facts.types) |> Enum.sort()
          aliases = Enum.with_index(facts.witness, fn _, i -> "selecto_upsert_witness_#{i}" end)
          true = Enum.all?(aliases, &(not Map.has_key?(facts.schema, &1)))
          projection = Enum.zip_with(facts.witness, aliases, &"#{q(&1)} AS #{q(&2)}")

          where =
            Enum.map_join(arbiter.fields, " AND ", fn {field, coll} ->
              "#{q(field)} COLLATE #{q(coll)} = ?"
            end)

          query =
            "SELECT " <>
              Enum.join(projection ++ Enum.map(fields, &q/1), ",") <>
              " FROM main.#{q(facts.table)} WHERE #{where} LIMIT 2"

          with {:ok, %{rows: rows, columns: columns}} <-
                 Adapter.execute(connection, query, Enum.map(keys, &native_parameter/1), opts),
               true <- :erlang.external_size(rows) <= @max_bytes do
            case rows do
              [] ->
                {:ok,
                 %{branch: :insert, physical_id: nil, prior: %{}, arbiter: arbiter, keys: keys}}

              [row] ->
                values = Map.new(Enum.zip(columns, row))

                {:ok,
                 %{
                   branch: :conflict,
                   physical_id: Enum.map(aliases, &Map.fetch!(values, &1)),
                   prior: Map.drop(values, aliases),
                   arbiter: arbiter,
                   keys: keys
                 }}

              _ ->
                pending()
            end
          else
            _ -> pending()
          end
        end)
      end
    end
  end

  defp candidate(connection, request, facts, inserted, %{branch: :insert}, opts) do
    with {:ok, values} <-
           project_values(
             connection,
             :insert,
             inserted,
             facts.types,
             facts.dependencies,
             request.context,
             opts
           ) do
      {:ok, values, %{}, :insert}
    end
  end

  defp candidate(connection, request, facts, inserted, %{branch: :conflict, prior: prior}, opts) do
    with {:ok, prior_values} <-
           project_values(
             connection,
             :update,
             prior,
             facts.types,
             facts.dependencies,
             request.context,
             opts
           ),
         {:ok, values} <-
           project_values(
             connection,
             :update,
             Map.merge(prior_values, Map.take(inserted, facts.mask)),
             facts.types,
             facts.dependencies,
             request.context,
             opts
           ) do
      {:ok, values, prior_values, if(facts.mask == [], do: :nothing, else: :update)}
    end
  end

  defp project_values(connection, operation, values, types, dependencies, context, opts) do
    with {:ok, values} <-
           literal_defaults(connection, operation, values, types, dependencies, opts) do
      request = %RuleCandidateRequest{
        operation: operation,
        relation: Keyword.fetch!(opts, :upsert_relation),
        values: values,
        field_types: types,
        context: Map.put(context, :selecto_rule_candidate_dependencies, dependencies)
      }

      case RuleCandidate.project(connection, request, opts) do
        {:ok, %{values: values, complete?: true, protection: protection}}
        when protection in [:locked, :serializable] ->
          {:ok, values}

        _ ->
          pending()
      end
    end
  end

  # Only verified literal syntax can enter this SELECT. We never evaluate a
  # schema expression, function, comment or volatile keyword to predict what a
  # later INSERT will store. The omission is retained in the actual command.
  defp literal_defaults(connection, :insert, values, types, dependencies, opts) do
    dependencies = if dependencies == :all, do: Map.keys(types), else: dependencies

    QueryGuard.run(connection, fn ->
      with {:ok, table} <- main_table(Keyword.fetch!(opts, :upsert_relation)),
           {:ok, schema} <- InsertAdmission.storage_schema(connection, table, opts, :insert),
           {:ok, dependencies} <- canonical_fields(dependencies, schema) do
        Enum.reduce_while(dependencies, {:ok, values}, fn field, {:ok, values} ->
          cond do
            Map.has_key?(values, field) ->
              {:cont, {:ok, values}}

            schema[field].rowid_alias ->
              {:halt, pending()}

            is_nil(schema[field].default_sql) ->
              {:cont, {:ok, Map.put(values, field, nil)}}

            true ->
              with {:ok, literal} <- default_literal(schema[field].default_sql),
                   {:ok, %{rows: [[value]]}} <-
                     Adapter.execute(connection, "SELECT " <> literal, [], opts) do
                {:cont, {:ok, Map.put(values, field, value)}}
              else
                _ -> {:halt, pending()}
              end
          end
        end)
      else
        _ -> pending()
      end
    end)
  end

  defp literal_defaults(_connection, _operation, values, _types, _dependencies, _opts),
    do: {:ok, values}

  defp default_literal(sql) when is_binary(sql) and byte_size(sql) in 1..4096 do
    with false <- String.contains?(sql, <<0>>),
         {:ok, literal} <- unwrap_literal(String.trim(sql), 0),
         true <- literal_syntax?(literal) do
      {:ok, literal}
    else
      _ -> pending()
    end
  end

  defp default_literal(_), do: pending()

  defp unwrap_literal(<<"(", _::binary>> = sql, depth) when depth < 16 do
    if outer_parentheses?(sql) do
      sql |> binary_part(1, byte_size(sql) - 2) |> String.trim() |> unwrap_literal(depth + 1)
    else
      pending()
    end
  end

  defp unwrap_literal(<<"(", _::binary>>, _depth), do: pending()
  defp unwrap_literal(sql, _depth), do: {:ok, sql}

  defp outer_parentheses?(sql), do: parens(sql, 0, false)
  defp parens(<<>>, 0, false), do: true
  defp parens(<<>>, _depth, _quoted), do: false
  defp parens(<<"''", rest::binary>>, depth, true), do: parens(rest, depth, true)
  defp parens(<<"'", rest::binary>>, depth, quoted), do: parens(rest, depth, not quoted)
  defp parens(<<"(", rest::binary>>, depth, false), do: parens(rest, depth + 1, false)
  defp parens(<<")", rest::binary>>, 1, false), do: rest == <<>>

  defp parens(<<")", rest::binary>>, depth, false) when depth > 1,
    do: parens(rest, depth - 1, false)

  defp parens(<<_char, rest::binary>>, depth, quoted) when depth > 0,
    do: parens(rest, depth, quoted)

  defp parens(_, _, _), do: false

  defp literal_syntax?(literal) do
    ascii_upcase(literal) in ["NULL", "TRUE", "FALSE"] or
      Regex.match?(
        ~r/\A[+-]?(?:(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?|0[xX][0-9a-fA-F]+)\z/,
        literal
      ) or
      Regex.match?(~r/\A'(?:[^']|'')*'\z/s, literal)
  end

  defp same_selection(nil, _selection), do: :ok

  defp same_selection(previous, selection) do
    if previous.branch == selection.branch and previous.physical_id === selection.physical_id and
         previous.arbiter == selection.arbiter and previous.prior === selection.prior,
       do: :ok,
       else: pending()
  end

  defp register(connection, request, facts, selection, values, inserted, effect, tracker) do
    registry = registry(tracker)
    rows = Process.get(tracker, %{})
    key = {fold(facts.table), selection.physical_id}
    existing = if selection.physical_id, do: Map.get(rows, key), else: nil

    if (map_size(registry.subjects) < @max_subjects or
          Map.has_key?(registry.subjects, request.subject)) and
         (is_nil(existing) or existing == {:upsert, request.subject}) do
      receipt = make_ref()

      entry =
        Map.merge(facts, selection)
        |> Map.merge(%{
          connection: connection,
          subject: request.subject,
          context: request.context,
          command: strip(request.command),
          values: values,
          inserted: inserted,
          effect: effect,
          field_types: request.field_types,
          receipt: receipt
        })

      receipts = Map.delete(registry.receipts, Map.get(registry.subjects, request.subject))

      registry = %{
        registry
        | receipts: Map.put(receipts, receipt, entry),
          subjects: Map.put(registry.subjects, request.subject, receipt)
      }

      rows = Map.put(rows, @registry, registry)

      rows =
        if selection.physical_id, do: Map.put(rows, key, {:upsert, request.subject}), else: rows

      Process.put(tracker, rows)
      {:ok, receipt}
    else
      pending(:ambiguous_candidate_identity)
    end
  end

  defp receipt_entries(connection, commands, opts) do
    Enum.reduce_while(commands, {:ok, []}, fn command, {:ok, entries} ->
      case Map.get(command.metadata, :protected_upsert_receipt) do
        nil ->
          if requires_receipt?(command), do: {:halt, pending()}, else: {:cont, {:ok, entries}}

        receipt ->
          with {:ok, tracker} <- tracker(opts),
               :ok <- Adapter.require_committed_reads(connection, opts),
               registry = registry(tracker),
               {:ok, entry} <- Map.fetch(registry.receipts, receipt),
               true <- entry.connection === connection and entry.command === strip(command),
               true <- entry.context === Keyword.get(opts, :context, %{}),
               true <- entry.subject === Map.get(command.metadata, :protected_upsert_subject),
               true <- Map.get(registry.subjects, entry.subject) === receipt,
               {:ok, %{rows: [[version]]}} <-
                 Adapter.execute(connection, "PRAGMA main.schema_version", [], opts),
               true <- version == entry.schema_version,
               {:ok, selection} <- select_branch(connection, entry, entry.inserted, opts),
               :ok <- same_selection(entry, selection) do
            {:cont, {:ok, entries ++ [entry]}}
          else
            {:error, %Error{}} = error -> {:halt, error}
            _ -> {:halt, pending()}
          end
      end
    end)
  end

  defp dependencies(connection, commands, entries, opts) do
    subjects = Enum.map(entries, & &1.subject)

    with true <- length(subjects) == MapSet.size(MapSet.new(subjects)) do
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        Enum.reduce_while(commands, :ok, fn command, :ok ->
          cond do
            Map.get(command.metadata, :protected_upsert_subject) === entry.subject ->
              {:cont, :ok}

            not same_table?(command.relation, entry.table) ->
              {:cont, :ok}

            generated_identity?(entry) ->
              {:halt, pending()}

            Map.has_key?(command.metadata, :protected_upsert_receipt) ->
              other =
                Enum.find(entries, &(&1.subject === command.metadata.protected_upsert_subject))

              case independent(connection, entry, other, opts) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end

            true ->
              case SelectoDBSQLite.UpsertIndependence.validate(connection, entry, command, opts) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end
          end
        end)
        |> case do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      _ -> pending(:ambiguous_candidate_identity)
    end
  end

  # Sync cleanup is materialized only after row results exist. Those symbolic
  # retained identities are not evidence that a prepared candidate is excluded.
  # Other-table cleanup remains governed by the ordinary ownership/effect proof.
  defp cleanup_dependencies(%Graph{nodes: nodes}, entries) do
    if Enum.any?(nodes, fn node ->
         node.delete_missing? and
           Enum.any?(entries, &same_table?(node.relation, &1.table))
       end),
       do: pending(),
       else: :ok
  end

  defp cleanup_dependencies(_write, _entries), do: :ok

  defp independent(_connection, _entry, %{effect: :nothing}, _opts), do: :ok

  defp independent(connection, entry, other, opts) do
    with true <- other != nil,
         false <- generated_identity?(other),
         true <- is_nil(entry.physical_id) or entry.physical_id !== other.physical_id,
         true <-
           Enum.all?(entry.arbiter.fields, fn {field, _} -> Map.has_key?(other.values, field) end),
         other_keys =
           Enum.map(entry.arbiter.fields, fn {field, _} -> Map.fetch!(other.values, field) end),
         {:ok, equal?} <-
           equal_keys(connection, entry.arbiter.fields, entry.keys, other_keys, opts),
         false <- equal? do
      :ok
    else
      _ -> pending(:ambiguous_candidate_identity)
    end
  end

  defp generated_identity?(%{branch: :insert, arbiter: %{kind: :rowid}, keys: keys}),
    do: Enum.any?(keys, &is_nil/1)

  defp generated_identity?(_entry), do: false

  defp equal_keys(_connection, _fields, left, right, _opts)
       when left == [] or right == [], do: pending()

  defp equal_keys(connection, fields, left, right, opts) do
    if Enum.any?(left ++ right, &is_nil/1) do
      {:ok, false}
    else
      query =
        "SELECT " <>
          Enum.map_join(fields, " AND ", fn {_field, coll} ->
            "(? COLLATE #{q(coll)}) = (? COLLATE #{q(coll)})"
          end)

      params =
        Enum.zip(left, right)
        |> Enum.flat_map(fn {a, b} -> [native_parameter(a), native_parameter(b)] end)

      QueryGuard.run(connection, fn ->
        case Adapter.execute(connection, query, params, opts) do
          {:ok, %{rows: [[value]]}} when value in [0, 1] -> {:ok, value == 1}
          _ -> pending()
        end
      end)
    end
  end

  defp native_parameter(%Decimal{} = value) do
    integer = Decimal.round(value, 0)

    if Decimal.equal?(value, integer) and
         Decimal.compare(value, Decimal.new(-9_223_372_036_854_775_808)) != :lt and
         Decimal.compare(value, Decimal.new(9_223_372_036_854_775_807)) != :gt,
       do: Decimal.to_integer(value),
       else: Decimal.to_float(value)
  end

  defp native_parameter(value), do: value

  defp commands(%Command{} = command), do: [command]
  defp commands(%Batch{commands: commands}), do: commands

  defp commands(%Graph{nodes: nodes}),
    do: Enum.flat_map(nodes, &Enum.map(&1.rows, fn row -> row.command end))

  defp commands(_), do: :invalid

  defp strip(command), do: %{command | metadata: Map.drop(command.metadata, @receipt_keys)}

  defp requires_receipt?(command),
    do:
      Map.has_key?(command.metadata, :protected_upsert_subject) or
        :protected_upsert_candidates in command.required_capabilities

  defp same_table?(relation, table) do
    case main_table(relation) do
      {:ok, name} -> fold(name) == fold(table)
      _ -> false
    end
  end

  defp q(value), do: Adapter.quote_identifier(value)

  defp fold(value),
    do: for(<<c <- value>>, into: <<>>, do: <<if(c in ?A..?Z, do: c + 32, else: c)>>)

  defp ascii_upcase(value),
    do: for(<<c <- value>>, into: <<>>, do: <<if(c in ?a..?z, do: c - 32, else: c)>>)

  defp pending(code \\ :required_data_rule_pending),
    do:
      {:error,
       Error.new(:validation, "SQLite cannot establish the protected UPSERT candidate",
         details: %{code: code, adapter: :sqlite}
       )}
end
