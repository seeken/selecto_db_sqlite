defmodule SelectoDBSQLite.Mutation do
  @moduledoc false
  alias Selecto.Write.Error
  alias SelectoDBSQLite.{Adapter, WriteCompiler}

  @types [:integer, :decimal, :string, :boolean]
  @operators %{add: "+", subtract: "-", multiply: "*", divide: "/"}

  def compile(ast, opts, offset) do
    if bounded?(ast, 0) and nodes(ast) <= 256,
      do: node(ast, opts, offset),
      else: invalid()
  end

  # Use the same expression compiler as DML. Root references resolve against
  # bound protected prior values, so simultaneous assignments read the old row.
  def resolve(connection, request, opts) do
    if Enum.any?(request.values, fn {_field, value} -> match?({:mutation, _}, value) end) do
      source = Map.get(request.context, :selecto_mutation_source, %{})
      types = Map.new(request.field_types, fn {field, type} -> {to_string(field), type} end)
      source = Map.new(source, fn {field, value} -> {to_string(field), value} end)

      compile_opts = [mutation_field_types: types, predicate_relation_alias: "mutation_source"]

      with true <- is_map(source),
           {:ok, projections, params} <- values(request.values, compile_opts),
           {:ok, columns, source_params} <- source_columns(source, types),
           sql =
             "SELECT " <>
               Enum.join(projections, ", ") <>
               " FROM (SELECT " <> Enum.join(columns, ", ") <> ") AS mutation_source",
           {:ok, %{rows: [row]}} <-
             Adapter.execute(connection, sql, params ++ source_params, opts) do
        fields =
          request.values
          |> Enum.sort_by(fn {field, _} -> to_string(field) end)
          |> Enum.map(fn {field, _} -> to_string(field) end)

        {:ok, %{request | values: Map.new(Enum.zip(fields, row))}}
      else
        _ -> invalid()
      end
    else
      {:ok, request}
    end
  end

  defp values(values, opts) do
    values
    |> Enum.sort_by(fn {field, _} -> to_string(field) end)
    |> Enum.reduce_while({:ok, [], []}, fn {_field, value}, {:ok, texts, params} ->
      value = if match?({:mutation, _}, value), do: value, else: {:literal, value}

      case WriteCompiler.compile_value(value, opts, length(params)) do
        {:ok, compiled} -> {:cont, {:ok, texts ++ [compiled.text], params ++ compiled.params}}
        error -> {:halt, error}
      end
    end)
  end

  defp source_columns(source, types) do
    Enum.reduce_while(Enum.sort(source), {:ok, [], []}, fn {field, value}, {:ok, texts, params} ->
      case storage_type(Map.get(types, field)) do
        nil ->
          {:halt, invalid()}

        type ->
          {:ok, compiled} = WriteCompiler.compile_value({:literal, value})

          text =
            "CAST(" <>
              compiled.text <> " AS " <> type <> ") AS " <> Adapter.quote_identifier(field)

          {:cont, {:ok, texts ++ [text], params ++ compiled.params}}
      end
    end)
    |> case do
      {:ok, [], []} -> {:ok, ["1 AS mutation_dummy"], []}
      result -> result
    end
  end

  defp node({:literal, value, type}, _opts, offset) when type in @types do
    with true <- scalar?(value),
         {:ok, compiled} <- WriteCompiler.compile_value({:literal, value}, [], offset) do
      if is_nil(value),
        do:
          {:ok,
           %{compiled | text: "CAST(" <> compiled.text <> " AS " <> storage_type(type) <> ")"}},
        else: {:ok, compiled}
    else
      _ -> invalid()
    end
  end

  defp node({:field, field, type}, opts, _offset) when is_binary(field) and type in @types do
    types = Keyword.get(opts, :mutation_field_types, %{})

    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, field) and
         storage_type(Map.get(types, field)) == storage_type(type) do
      WriteCompiler.compile_value({:field, field}, opts)
    else
      invalid()
    end
  end

  defp node({kind, args, type}, opts, offset)
       when kind in [:add, :subtract, :multiply, :divide, :coalesce] and type in @types do
    with true <- is_list(args),
         true <- if(kind == :coalesce, do: length(args) in 2..16, else: length(args) == 2),
         true <- kind == :coalesce or type in [:integer, :decimal],
         {:ok, texts, params} <- operands(args, opts, offset) do
      text =
        if kind == :coalesce,
          do: "COALESCE(" <> Enum.join(texts, ", ") <> ")",
          else: "(" <> Enum.join(texts, " " <> Map.fetch!(@operators, kind) <> " ") <> ")"

      {:ok, %{text: text, params: params}}
    else
      _ -> invalid()
    end
  end

  defp node(_ast, _opts, _offset), do: invalid()

  defp operands(args, opts, offset) do
    Enum.reduce_while(args, {:ok, [], []}, fn ast, {:ok, texts, params} ->
      case node(ast, opts, offset + length(params)) do
        {:ok, compiled} -> {:cont, {:ok, texts ++ [compiled.text], params ++ compiled.params}}
        error -> {:halt, error}
      end
    end)
  end

  defp bounded?(_ast, depth) when depth >= 32, do: false
  defp bounded?({kind, _value, _type}, _depth) when kind in [:literal, :field], do: true

  defp bounded?({_kind, args, _type}, depth) when is_list(args),
    do: Enum.all?(args, &bounded?(&1, depth + 1))

  defp bounded?(_, _), do: false
  defp nodes({kind, _, _}) when kind in [:literal, :field], do: 1
  defp nodes({_, args, _}), do: 1 + Enum.sum(Enum.map(args, &nodes/1))

  defp scalar?(value)
       when is_nil(value) or is_binary(value) or is_integer(value) or is_float(value) or
              is_boolean(value),
       do: true

  defp scalar?(%Decimal{}), do: true
  defp scalar?(_), do: false

  defp storage_type(type)
       when type in [:integer, "integer", :bigint, "bigint", :boolean, "boolean"], do: "INTEGER"

  defp storage_type(type)
       when type in [:decimal, "decimal", :numeric, "numeric", :float, "float"], do: "NUMERIC"

  defp storage_type(type)
       when type in [
              :string,
              "string",
              :text,
              "text",
              :uuid,
              "uuid",
              :date,
              "date",
              :naive_datetime,
              "naive_datetime",
              :utc_datetime,
              "utc_datetime"
            ],
       do: "TEXT"

  defp storage_type(_), do: nil

  defp invalid,
    do:
      {:error,
       Error.new(:invalid_write, "Invalid bounded SQLite mutation expression",
         details: %{code: :invalid_write}
       )}
end
