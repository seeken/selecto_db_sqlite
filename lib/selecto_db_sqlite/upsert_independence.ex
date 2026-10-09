defmodule SelectoDBSQLite.UpsertIndependence do
  @moduledoc false
  alias Selecto.Write.{Command, Error}
  alias SelectoDBSQLite.{Adapter, InsertAdmission, QueryGuard, UpsertCandidate, WriteCompiler}

  # These proofs are independent of plan order. In particular, a key-changing
  # UPDATE cannot rely on an initially empty selection: an earlier INSERT may
  # make that predicate match before dispatch.
  def validate(connection, entry, %Command{} = command, opts) do
    case command.operation do
      :insert ->
        insertion_disjoint(connection, entry, command, opts)

      :upsert ->
        upsert_disjoint(connection, entry, command, opts)

      operation when operation in [:update, :delete] ->
        with :ok <- selected_row_disjoint(connection, entry, command, opts),
             :ok <- prospective_row_disjoint(connection, entry, command, opts) do
          if operation == :delete,
            do: :ok,
            else: changed_key_disjoint(connection, entry, command, nil, opts)
        end

      _ ->
        pending()
    end
  rescue
    _ -> pending()
  end

  defp insertion_disjoint(connection, entry, command, opts) do
    with {:ok, values} <- assignments(command, entry, context(entry, opts)),
         {:ok, projected} <-
           UpsertCandidate.project_values(
             connection,
             :insert,
             command.relation,
             Map.take(values, entry.target),
             entry.types,
             entry.target,
             context(entry, opts),
             opts
           ),
         {:ok, keys} <- field_values(projected, entry.target),
         {:ok, false} <-
           UpsertCandidate.keys_equal(connection, entry.arbiter, entry.keys, keys, opts) do
      :ok
    else
      _ -> pending()
    end
  end

  defp upsert_disjoint(connection, entry, command, opts) do
    with {:ok, prospective} <-
           UpsertCandidate.prospective(
             connection,
             command,
             entry.types,
             entry.target,
             context(entry, opts),
             opts
           ),
         true <- entry.physical_id == nil or prospective.physical_id != entry.physical_id,
         :ok <- insertion_disjoint(connection, entry, command, opts),
         :ok <- changed_key_disjoint(connection, entry, command, prospective.mask, opts) do
      :ok
    else
      _ -> pending()
    end
  end

  defp selected_row_disjoint(_connection, %{physical_id: nil}, _command, _opts), do: :ok

  defp selected_row_disjoint(connection, entry, command, opts) do
    QueryGuard.run(connection, fn ->
      with {:ok, predicate} <-
             WriteCompiler.compile_predicate(command.predicate, context: context(entry, opts)),
           {:ok, %{rows: rows}} <-
             Adapter.execute(
               connection,
               "SELECT " <>
                 Enum.map_join(entry.witness, ",", &Adapter.quote_identifier/1) <>
                 " FROM main." <>
                 Adapter.quote_identifier(entry.table) <>
                 " WHERE " <> predicate.text <> " LIMIT 1001",
               predicate.params,
               opts
             ),
           true <- length(rows) <= 1000,
           false <- Enum.any?(rows, &(&1 == entry.physical_id)) do
        :ok
      else
        _ -> pending()
      end
    end)
  end

  # The stored-row query alone is insufficient: an INSERT can create a match,
  # and an UPSERT update can make a previously false predicate become true.
  # Evaluate the actual predicate against the final native-affinity candidate.
  # InsertAdmission supplies the same column affinity/collation as real DML;
  # unavailable generated/default values remain a typed pending proof.
  defp prospective_row_disjoint(connection, entry, command, opts) do
    with {:ok, predicate, fields, _remaining} <-
           canonical_predicate(command.predicate, entry.schema, 1024, 0),
         {:ok, values} <-
           UpsertCandidate.project_values(
             connection,
             if(entry.branch == :insert, do: :insert, else: :update),
             entry.command.relation,
             entry.values,
             entry.types,
             fields,
             context(entry, opts),
             opts
           ) do
      # Include RHS field references in the projection as well. These guards
      # are true for every SQL value, including NULL, and do not change p.
      available =
        Enum.map(fields, fn field ->
          {:or, [{:is_null, {:field, field}}, {:not_null, {:field, field}}]}
        end)

      projection = %Command{
        operation: :insert,
        relation: entry.command.relation,
        assignments:
          Enum.map(Map.take(values, fields), fn {field, value} ->
            %{field: field, value: {:literal, value}}
          end),
        metadata: %{
          field_types: entry.types,
          insert_admission: %{
            storage_backend: :sqlite,
            predicate: {:and, available ++ [predicate]}
          }
        }
      }

      QueryGuard.run(connection, fn ->
        case InsertAdmission.enforce(connection, projection, opts) do
          {:error, %Error{details: %{code: :query_rule_violation}}} -> :ok
          _ -> pending()
        end
      end)
    else
      _ -> pending()
    end
  end

  defp canonical_predicate(_predicate, _schema, remaining, depth)
       when remaining <= 0 or depth > 64,
       do: pending()

  defp canonical_predicate({kind, predicates}, schema, remaining, depth)
       when kind in [:and, :or] and is_list(predicates) and predicates != [] do
    Enum.reduce_while(predicates, {:ok, [], [], remaining - 1}, fn predicate,
                                                                   {:ok, terms, fields, left} ->
      case canonical_predicate(predicate, schema, left, depth + 1) do
        {:ok, term, next_fields, next} ->
          {:cont, {:ok, [term | terms], Enum.uniq(fields ++ next_fields), next}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, terms, fields, left} -> {:ok, {kind, Enum.reverse(terms)}, fields, left}
      error -> error
    end
  end

  defp canonical_predicate({:not, predicate}, schema, remaining, depth) do
    with {:ok, predicate, fields, left} <-
           canonical_predicate(predicate, schema, remaining - 1, depth + 1),
         do: {:ok, {:not, predicate}, fields, left}
  end

  defp canonical_predicate({kind, {:field, field}}, schema, remaining, _depth)
       when kind in [:is_null, :not_null] do
    case canonical_field(field, schema) do
      field when is_binary(field) -> {:ok, {kind, {:field, field}}, [field], remaining - 1}
      _ -> pending()
    end
  end

  defp canonical_predicate({kind, {:field, field}, value}, schema, remaining, _depth)
       when kind in [:eq, :neq, :gt, :gte, :lt, :lte, :in] do
    with field when is_binary(field) <- canonical_field(field, schema),
         {:ok, value, fields, left} <- canonical_value(value, schema, remaining - 1) do
      {:ok, {kind, {:field, field}, value}, Enum.uniq([field | fields]), left}
    else
      _ -> pending()
    end
  end

  defp canonical_predicate(_, _, _, _), do: pending()

  defp canonical_value(_value, _schema, remaining) when remaining <= 0, do: pending()

  defp canonical_value({:field, field}, schema, remaining) do
    case canonical_field(field, schema) do
      field when is_binary(field) -> {:ok, {:field, field}, [field], remaining - 1}
      _ -> pending()
    end
  end

  defp canonical_value({:literal, {:system, _}}, _, _), do: pending()

  defp canonical_value({kind, _} = value, _schema, remaining) when kind in [:literal, :context],
    do: {:ok, value, [], remaining - 1}

  defp canonical_value(values, schema, remaining) when is_list(values) do
    Enum.reduce_while(values, {:ok, [], [], remaining - 1}, fn value,
                                                               {:ok, terms, fields, left} ->
      case canonical_value(value, schema, left) do
        {:ok, value, next_fields, next} ->
          {:cont, {:ok, [value | terms], Enum.uniq(fields ++ next_fields), next}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, terms, fields, left} -> {:ok, Enum.reverse(terms), fields, left}
      error -> error
    end
  end

  defp canonical_value(value, _schema, remaining)
       when is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value),
       do: {:ok, value, [], remaining - 1}

  defp canonical_value(_, _, _), do: pending()

  defp changed_key_disjoint(connection, entry, command, mask, opts) do
    mask = if is_nil(mask), do: Enum.map(command.assignments, & &1.field), else: mask
    mask = Enum.map(mask, &canonical_field(&1, entry.schema))
    true = Enum.all?(mask, &is_binary/1)
    changed = Enum.filter(entry.arbiter.fields, fn {field, _} -> field in mask end)

    cond do
      changed == [] or Enum.any?(entry.keys, &is_nil/1) ->
        :ok

      true ->
        fields = Enum.map(changed, &elem(&1, 0))

        with {:ok, values} <- assignments(command, entry, context(entry, opts)),
             {:ok, projected} <-
               UpsertCandidate.project_values(
                 connection,
                 :update,
                 command.relation,
                 Map.take(values, fields),
                 entry.types,
                 fields,
                 context(entry, opts),
                 opts
               ) do
          Enum.reduce_while(changed, pending(), fn {field, collation}, _ ->
            original = Enum.zip(entry.target, entry.keys) |> Map.new() |> Map.fetch!(field)
            arbiter = %{entry.arbiter | fields: [{field, collation}]}

            case UpsertCandidate.keys_equal(
                   connection,
                   arbiter,
                   [original],
                   [Map.fetch!(projected, field)],
                   opts
                 ) do
              {:ok, false} -> {:halt, :ok}
              {:ok, true} -> {:cont, pending()}
              _ -> {:halt, pending()}
            end
          end)
        else
          _ -> pending()
        end
    end
  end

  defp assignments(command, entry, context) do
    Enum.reduce_while(command.assignments, {:ok, %{}}, fn %{field: field, value: value},
                                                          {:ok, values} ->
      field = canonical_field(field, entry.schema)

      resolved =
        case value do
          {:literal, literal} -> {:ok, literal}
          {:context, key} -> Map.fetch(context, key)
          _ -> :error
        end

      case resolved do
        {:ok, literal} when is_binary(field) ->
          if Map.has_key?(values, field),
            do: {:halt, pending()},
            else: {:cont, {:ok, Map.put(values, field, literal)}}

        _ ->
          {:halt, pending()}
      end
    end)
  end

  defp field_values(values, fields) do
    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, result} ->
      case Map.fetch(values, to_string(field)) do
        {:ok, value} -> {:cont, {:ok, result ++ [value]}}
        _ -> {:halt, pending()}
      end
    end)
  end

  defp context(entry, opts), do: Keyword.get(opts, :context, entry.context)

  defp canonical_field(field, schema),
    do: Enum.find(Map.keys(schema), &(ascii_fold(&1) == ascii_fold(to_string(field))))

  defp ascii_fold(text),
    do: for(<<char <- text>>, into: "", do: <<if(char in ?A..?Z, do: char + 32, else: char)>>)

  defp pending do
    {:error,
     Error.new(:validation, "SQLite cannot prove independent protected upsert effects",
       details: %{code: :required_data_rule_pending, adapter: :sqlite}
     )}
  end
end
