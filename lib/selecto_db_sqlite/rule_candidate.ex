defmodule SelectoDBSQLite.RuleCandidate do
  @moduledoc false
  alias Selecto.Write.{Error, RecordState, RuleCandidateRequest}
  alias SelectoDBSQLite.{Adapter, InsertAdmission}

  @declaration ~r/\A[A-Z][A-Z0-9_]*(?:\(\s*\d+\s*(?:,\s*\d+\s*)?\))?\z/

  def project(connection, %RuleCandidateRequest{} = request, opts) do
    with true <- request.operation in [:insert, :update, :delete],
         true <-
           request.format == "selecto.rule_candidate_request" and request.format_version == 1,
         true <- is_map(request.values) and is_map(request.field_types),
         {:ok, table} <- table(request.relation),
         {:ok, schema} <- InsertAdmission.storage_schema(connection, table, opts),
         {:ok, request} <- available_dependencies(request, schema),
         {:ok, request} <- SelectoDBSQLite.Mutation.resolve(connection, request, opts),
         {:ok, fields, definitions, params} <- columns(request, schema) do
      project_row(connection, request, fields, definitions, params, opts)
    else
      _ -> pending()
    end
  rescue
    _ -> pending()
  end

  defp table(relation) do
    case String.split(to_string(relation), ".") do
      [name] when name != "" -> {:ok, name}
      ["main", name] when name != "" -> {:ok, name}
      _ -> :error
    end
  end

  defp columns(request, schema) do
    types =
      Map.new(request.field_types, fn {field, type} -> {to_string(field), to_string(type)} end)

    values = Map.new(request.values, fn {field, value} -> {to_string(field), value} end)

    if Enum.all?(values, fn {field, _} -> Map.has_key?(types, field) end) do
      values
      |> Enum.sort()
      |> Enum.reduce_while({:ok, [], [], []}, fn {field, value},
                                                 {:ok, fields, definitions, params} ->
        kind = Map.fetch!(types, field)

        with %{hidden: 0} = column <- Map.get(schema, field),
             true <- Regex.match?(@declaration, column.declared_type) do
          if request.operation == :insert and is_nil(value) and column.rowid_alias do
            # Availability already refused this value if any rule consumes it.
            {:cont, {:ok, fields, definitions, params}}
          else
            with true <- compatible?(kind, column.declared_type),
                 {:ok, value} <- parameter(kind, value) do
              definition =
                Adapter.quote_identifier(field) <>
                  " " <>
                  column.declared_type <>
                  " COLLATE " <> Adapter.quote_identifier(column.collation)

              {:cont,
               {:ok, fields ++ [{field, kind}], definitions ++ [definition], params ++ [value]}}
            else
              _ -> {:halt, pending()}
            end
          end
        else
          _ -> {:halt, pending()}
        end
      end)
    else
      pending()
    end
  end

  defp available_dependencies(request, schema) do
    types = Map.new(request.field_types, fn {field, type} -> {to_string(field), type} end)
    values = Map.new(request.values, fn {field, value} -> {to_string(field), value} end)
    dependencies = Map.get(request.context, :selecto_rule_candidate_dependencies, :all)
    dependencies = if dependencies == :all, do: Map.keys(types), else: dependencies

    if is_list(dependencies) do
      dependencies
      |> Enum.reduce_while({:ok, values}, fn field, {:ok, current} ->
        field = to_string(field)

        case Map.get(schema, field) do
          %{rowid_alias: true} when request.operation == :insert ->
            if Map.get(current, field) == nil,
              do: {:halt, pending()},
              else: {:cont, {:ok, current}}

          %{default_sql: default} ->
            cond do
              not Map.has_key?(types, field) ->
                {:halt, pending()}

              Map.has_key?(current, field) ->
                {:cont, {:ok, current}}

              request.operation == :insert and is_nil(default) ->
                {:cont, {:ok, Map.put(current, field, nil)}}

              true ->
                {:halt, pending()}
            end

          _ ->
            {:halt, pending()}
        end
      end)
      |> case do
        {:ok, values} ->
          {:ok, %{request | values: values}}

        error ->
          error
      end
    else
      pending()
    end
  end

  defp compatible?(kind, declared) when kind in ["integer", "bigint"],
    do: String.contains?(declared, "INT")

  defp compatible?("boolean", declared),
    do: String.contains?(declared, "INT") or declared == "BOOLEAN"

  defp compatible?(kind, declared) when kind in ["decimal", "numeric"],
    do: Regex.match?(~r/\A(?:NUMERIC|DECIMAL)(?:\(\s*\d+\s*(?:,\s*\d+\s*)?\))?\z/, declared)

  defp compatible?(kind, declared)
       when kind in ["string", "text", "uuid", "date", "naive_datetime", "utc_datetime"],
       do: not String.contains?(declared, "INT") and Regex.match?(~r/CHAR|CLOB|TEXT/, declared)

  defp compatible?(_, _), do: false

  defp parameter(_, nil), do: {:ok, nil}
  defp parameter(_, %Decimal{} = value), do: {:ok, Decimal.to_string(value, :normal)}
  defp parameter(_, %Date{} = value), do: {:ok, Date.to_iso8601(value)}
  defp parameter(_, %NaiveDateTime{} = value), do: {:ok, NaiveDateTime.to_iso8601(value)}
  defp parameter(_, %DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}

  defp parameter(_, value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value),
       do: {:ok, value}

  defp parameter(_, _), do: :error

  defp project_row(_connection, request, [], _definitions, _params, _opts),
    do: {:ok, %RecordState{values: request.values, complete?: true, protection: :serializable}}

  defp project_row(connection, request, fields, definitions, params, opts) do
    name =
      Adapter.quote_identifier(
        "selecto_rule_candidate_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    savepoint =
      "selecto_rule_projection_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    with {:ok, _} <- Adapter.execute(connection, "SAVEPOINT " <> savepoint, [], opts) do
      result =
        try do
          with {:ok, _} <-
                 Adapter.execute(
                   connection,
                   "CREATE TEMP TABLE " <> name <> "(" <> Enum.join(definitions, ",") <> ")",
                   [],
                   opts
                 ),
               {:ok, _} <-
                 Adapter.execute(
                   connection,
                   "INSERT INTO " <>
                     name <> " VALUES(" <> Enum.map_join(fields, ",", fn _ -> "?" end) <> ")",
                   params,
                   opts
                 ),
               {:ok, %{rows: [row]}} <-
                 Adapter.execute(connection, "SELECT * FROM " <> name, [], opts),
               {:ok, projected} <- canonical(fields, row) do
            values =
              request.values
              |> Map.new(fn {field, value} -> {to_string(field), value} end)
              |> Map.merge(projected)

            {:ok, %RecordState{values: values, complete?: true, protection: :serializable}}
          else
            _ -> pending()
          end
        rescue
          _ -> pending()
        catch
          _, _ -> pending()
        end

      with {:ok, _} <-
             Adapter.execute(connection, "ROLLBACK TO SAVEPOINT " <> savepoint, [], opts),
           {:ok, _} <- Adapter.execute(connection, "RELEASE SAVEPOINT " <> savepoint, [], opts) do
        result
      else
        _ -> pending()
      end
    else
      _ -> pending()
    end
  end

  defp canonical(fields, row) do
    Enum.zip(fields, row)
    |> Enum.reduce_while({:ok, %{}}, fn {{field, kind}, value}, {:ok, values} ->
      case scalar(kind, value) do
        {:ok, value} -> {:cont, {:ok, Map.put(values, field, value)}}
        _ -> {:halt, pending()}
      end
    end)
  end

  defp scalar(_, nil), do: {:ok, nil}

  defp scalar(kind, value) when kind in ["integer", "bigint"] and is_integer(value),
    do: {:ok, value}

  defp scalar("boolean", value) when value in [0, 1], do: {:ok, value == 1}

  defp scalar(kind, value) when kind in ["decimal", "numeric"] and is_integer(value),
    do: {:ok, Decimal.new(value)}

  defp scalar(kind, value) when kind in ["decimal", "numeric"] and is_float(value),
    do: {:ok, Decimal.from_float(value)}

  defp scalar(kind, value)
       when kind in ["string", "text", "uuid", "date", "naive_datetime", "utc_datetime"] and
              is_binary(value),
       do: {:ok, value}

  defp scalar(_, _), do: :error

  defp pending do
    {:error,
     Error.new(:validation, "SQLite cannot establish the stored rule candidate",
       details: %{code: :required_data_rule_pending, adapter: :sqlite}
     )}
  end
end
