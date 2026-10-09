defmodule SelectoDBSQLite.InsertAdmission do
  @moduledoc false
  alias Selecto.Write.{Command, Error}
  alias SelectoDBSQLite.{Adapter, WriteCompiler}

  def enforce(
        connection,
        %Command{operation: :insert, metadata: %{insert_admission: admission}} = command,
        opts
      ) do
    with %{storage_backend: :sqlite, predicate: predicate} <- admission,
         {:ok, table} <- main_table(command.relation),
         {:ok, schema} <- storage_schema(connection, table, opts, :insert),
         {:ok, fields} <- predicate_fields(predicate),
         {:ok, candidate} <- candidate_columns(command, fields, schema, opts),
         {:ok, guard} <-
           WriteCompiler.compile_predicate(predicate, context: Keyword.get(opts, :context, %{})),
         sql =
           "SELECT CASE WHEN (#{guard.text}) THEN 1 ELSE 0 END FROM (SELECT #{candidate.sql}) AS selecto_candidate",
         {:ok, %{rows: [[allowed]]}} <-
           Adapter.execute(connection, sql, guard.params ++ candidate.params, opts) do
      if allowed == 1, do: :ok, else: denied(:query_rule_violation)
    else
      {:error, %Error{type: :query_enforcement}} = error -> error
      _ -> denied(:query_rule_not_evaluable)
    end
  rescue
    _ -> denied(:query_rule_not_evaluable)
  end

  def enforce(_connection, %Command{metadata: %{insert_admission: _}}, _opts),
    do: denied(:query_rule_not_evaluable)

  def enforce(_connection, _command, _opts), do: :ok

  defp main_table(relation) do
    case String.split(to_string(relation), ".") do
      [table] when table != "" -> {:ok, table}
      ["main", table] when table != "" -> {:ok, table}
      _ -> denied(:query_rule_not_evaluable)
    end
  end

  @doc false
  def storage_schema(connection, table, opts, operation \\ nil) do
    with true <- is_binary(table) and table != "",
         {:ok, %{rows: main_catalog}} <-
           Adapter.execute(
             connection,
             "SELECT type,name,tbl_name,sql FROM main.sqlite_schema",
             [],
             opts
           ),
         {:ok, %{rows: temp_catalog}} <-
           Adapter.execute(
             connection,
             "SELECT type,name,tbl_name,sql FROM temp.sqlite_schema",
             [],
             opts
           ),
         true <- catalog_rows?(main_catalog) and catalog_rows?(temp_catalog),
         [] <- Enum.filter(temp_catalog, fn [_, name, _, _] -> same_name?(name, table) end),
         [["table", actual_table, _, ddl]] <-
           Enum.filter(main_catalog, fn [_, name, _, _] -> same_name?(name, table) end),
         true <- is_binary(ddl) and Regex.match?(~r/\ACREATE\s+TABLE\b/i, ddl),
         false <- unsafe_conflict?(ddl, operation),
         {:ok, %{rows: table_list}} <-
           Adapter.execute(
             connection,
             "PRAGMA main.table_list",
             [],
             opts
           ),
         [["main", _, "table", _, without_rowid, _]] <-
           Enum.filter(table_list, fn
             ["main", name, _, _, _, _] -> same_name?(name, actual_table)
             _ -> false
           end),
         true <- without_rowid in [0, 1],
         [] <-
           Enum.filter(main_catalog ++ temp_catalog, fn [type, _, owner, _] ->
             type == "trigger" and same_name?(owner, actual_table)
           end),
         {:ok, %{rows: rows}} <-
           Adapter.execute(
             connection,
             "PRAGMA main.table_xinfo(#{Adapter.quote_identifier(actual_table)})",
             [],
             opts
           ),
         true <- rows != [] and Enum.all?(rows, &match?([_, _, _, _, _, _, 0], &1)),
         {:ok, %{rows: indexes}} <-
           Adapter.execute(
             connection,
             "PRAGMA main.index_list(#{Adapter.quote_identifier(actual_table)})",
             [],
             opts
           ),
         true <- Enum.all?(indexes, &match?([_, _, _, _, _], &1)),
         primary_indexes = Enum.filter(indexes, fn [_, _, _, origin, _] -> origin == "pk" end),
         {:ok, collations} <- column_collations(ddl),
         true <-
           Enum.all?(rows, fn [_, name | _] -> Map.has_key?(collations, ascii_fold(name)) end) do
      primary_count = Enum.count(rows, fn [_, _, _, _, _, pk, _] -> pk > 0 end)

      {:ok,
       Map.new(rows, fn [_cid, name, type, notnull, default, pk, hidden] ->
         {name,
          %{
            declared_type: ascii_upcase(type),
            hidden: hidden,
            primary_key: pk > 0,
            without_rowid: without_rowid,
            rowid_alias:
              without_rowid == 0 and primary_indexes == [] and primary_count == 1 and
                pk == 1 and ascii_upcase(type) == "INTEGER",
            nullable: notnull == 0,
            default_sql: default,
            collation: Map.fetch!(collations, ascii_fold(name))
          }}
       end)}
    else
      _ -> denied(:query_rule_not_evaluable)
    end
  end

  # SQL collations and table-valued PRAGMA functions can be supplied by the
  # connection's host. Catalog identity must follow SQLite's ASCII identifier
  # rules in the host, with facts read through native PRAGMA statements.
  defp same_name?(left, right) when is_binary(left) and is_binary(right),
    do: ascii_fold(left) == ascii_fold(right)

  defp same_name?(_, _), do: false

  defp catalog_rows?(rows) do
    Enum.all?(rows, fn
      [type, name, owner, ddl] ->
        is_binary(type) and is_binary(name) and is_binary(owner) and
          (is_nil(ddl) or is_binary(ddl))

      _ ->
        false
    end)
  end

  defp candidate_columns(command, required, schema, opts) do
    types =
      command.metadata
      |> Map.get(:field_types, %{})
      |> Map.new(fn {field, type} -> {to_string(field), type} end)

    context = Keyword.get(opts, :context, %{})

    assignments =
      Map.new(command.assignments, fn %{field: field, value: value} ->
        {to_string(field), value}
      end)

    with true <- Enum.all?(required, &Map.has_key?(assignments, &1)),
         {:ok, values} <- resolve_assignments(assignments, types, context) do
      required
      |> Enum.sort()
      |> Enum.reduce_while({:ok, [], []}, fn field, {:ok, columns, params} ->
        with %{hidden: 0} = column <- Map.get(schema, field),
             {:ok, cast} <- storage_cast(Map.get(types, field), column),
             {:ok, value} <- Map.fetch(values, field),
             true <-
               not (is_nil(value) and column.rowid_alias) do
          projection =
            "CAST(? AS #{cast}) COLLATE #{Adapter.quote_identifier(column.collation)} AS #{Adapter.quote_identifier(field)}"

          {:cont, {:ok, columns ++ [projection], params ++ [value]}}
        else
          _ -> {:halt, denied(:query_rule_not_evaluable)}
        end
      end)
      |> case do
        {:ok, [], []} -> {:ok, %{sql: "1 AS selecto_dummy", params: []}}
        {:ok, columns, params} -> {:ok, %{sql: Enum.join(columns, ", "), params: params}}
        error -> error
      end
    else
      _ -> denied(:query_rule_not_evaluable)
    end
  end

  defp resolve_assignments(assignments, types, context) do
    Enum.reduce_while(assignments, {:ok, %{}}, fn {field, expression}, {:ok, values} ->
      with {:ok, value} <- resolve_value(expression, context),
           true <- canonical?(Map.get(types, field), value) do
        {:cont, {:ok, Map.put(values, field, value)}}
      else
        _ -> {:halt, denied(:query_rule_not_evaluable)}
      end
    end)
  end

  defp resolve_value({:literal, value}, _context), do: {:ok, value}
  defp resolve_value({:context, key}, context), do: Map.fetch(context, key)
  defp resolve_value(_, _), do: :error

  defp canonical?(type, nil),
    do:
      type in [
        :integer,
        :bigint,
        :boolean,
        :string,
        :text,
        :decimal,
        :date,
        :naive_datetime,
        :utc_datetime,
        "integer",
        "bigint",
        "boolean",
        "string",
        "text",
        "decimal",
        "date",
        "naive_datetime",
        "utc_datetime"
      ]

  defp canonical?(type, value) when type in [:integer, :bigint, "integer", "bigint"],
    do: is_integer(value) and value in -9_223_372_036_854_775_808..9_223_372_036_854_775_807

  defp canonical?(type, value) when type in [:boolean, "boolean"], do: is_boolean(value)

  defp canonical?(type, value) when type in [:string, :text, "string", "text"],
    do: is_binary(value) and String.valid?(value)

  defp canonical?(type, %Decimal{} = value) when type in [:decimal, "decimal"],
    do: is_integer(value.coef) and finite_decimal?(value)

  defp canonical?(type, value) when type in [:decimal, "decimal"] and is_binary(value),
    do: Regex.match?(~r/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/, value) and finite_decimal?(value)

  defp canonical?(type, value) when type in [:decimal, "decimal"],
    do: is_integer(value) or is_float(value)

  defp canonical?(type, value) when type in [:date, "date"] and is_binary(value),
    do: match?({:ok, _}, Date.from_iso8601(value))

  defp canonical?(type, value)
       when type in [:naive_datetime, "naive_datetime"] and is_binary(value),
       do: match?({:ok, _}, NaiveDateTime.from_iso8601(value))

  defp canonical?(type, value) when type in [:utc_datetime, "utc_datetime"] and is_binary(value),
    do: match?({:ok, _, 0}, DateTime.from_iso8601(value))

  defp canonical?(_, _), do: false

  defp finite_decimal?(value) do
    value |> Decimal.new() |> Decimal.to_float() |> is_float()
  rescue
    _ -> false
  end

  defp storage_cast(type, %{declared_type: declaration} = column) do
    cond do
      column.collation not in ["BINARY", "NOCASE", "RTRIM"] ->
        :error

      type in [:integer, :bigint, "integer", "bigint"] and String.contains?(declaration, "INT") ->
        {:ok, "INTEGER"}

      type in [:boolean, "boolean"] and
          (String.contains?(declaration, "INT") or declaration == "BOOLEAN") ->
        {:ok, "INTEGER"}

      type in [:decimal, "decimal"] and
          Regex.match?(~r/\A(?:NUMERIC|DECIMAL)(?:\(\s*\d+\s*(?:,\s*\d+\s*)?\))?\z/, declaration) ->
        {:ok, "NUMERIC"}

      type in [
        :string,
        :text,
        :date,
        :naive_datetime,
        :utc_datetime,
        "string",
        "text",
        "date",
        "naive_datetime",
        "utc_datetime"
      ] and
        not String.contains?(declaration, "INT") and Regex.match?(~r/CHAR|CLOB|TEXT/, declaration) ->
        {:ok, "TEXT"}

      true ->
        :error
    end
  end

  defp predicate_fields({kind, predicates}) when kind in [:and, :or] and is_list(predicates),
    do: collect_fields(predicates)

  defp predicate_fields({:not, predicate}), do: predicate_fields(predicate)

  defp predicate_fields({kind, {:field, field}, _value})
       when kind in [:eq, :neq, :gt, :gte, :lt, :lte, :in], do: {:ok, [to_string(field)]}

  defp predicate_fields({kind, {:field, field}}) when kind in [:is_null, :not_null],
    do: {:ok, [to_string(field)]}

  defp predicate_fields(_), do: :error

  defp collect_fields(predicates) do
    Enum.reduce_while(predicates, {:ok, []}, fn predicate, {:ok, fields} ->
      case predicate_fields(predicate) do
        {:ok, next} -> {:cont, {:ok, Enum.uniq(fields ++ next)}}
        _ -> {:halt, :error}
      end
    end)
  end

  # SQLite preserves the CREATE TABLE text. Tokenize strings/comments and
  # quoted names separately, then inspect only each declaration's outer level.
  # This avoids treating COLLATE inside defaults or CHECK expressions as the
  # column collation, and refuses unrecognized custom collations conservatively.
  # A schema conflict policy applies even to a plain INSERT, UPDATE or upsert.
  # REPLACE can delete a conflicting row (including unrelated FK descendants),
  # or replace submitted NOT NULL values with defaults outside the proved row.
  # ROLLBACK on INSERT/UPDATE/upsert can destroy the caller's entire transaction,
  # including savepoints and work outside this write. DELETE and read anchors do
  # not invoke these constraint policies. REPLACE retains its existing refusal.
  # Quoted tokens remain distinct; comments may separate real SQL keywords.
  defp unsafe_conflict?(ddl, operation) do
    ddl
    |> ddl_tokens()
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.any?(fn tokens ->
      case Enum.map(tokens, &ascii_upcase/1) do
        ["ON", "CONFLICT", "REPLACE"] -> true
        ["ON", "CONFLICT", "ROLLBACK"] -> operation in [:insert, :update, :upsert]
        _ -> false
      end
    end)
  end

  defp ddl_tokens(ddl) do
    Regex.scan(
      ~r/--[^\n]*|\/\*[\s\S]*?\*\/|'(?:''|[^'])*'|"(?:""|[^"])*"|`(?:``|[^`])*`|\[[^\]]*\]|[A-Za-z_\x{80}-\x{10FFFF}][A-Za-z0-9_$\x{80}-\x{10FFFF}]*|\S/u,
      ddl
    )
    |> List.flatten()
    |> Enum.reject(&String.starts_with?(&1, ["--", "/*"]))
  end

  defp column_collations(ddl) do
    tokens = ddl_tokens(ddl)

    with [_open | body] <- Enum.drop_while(tokens, &(&1 != "(")),
         {:ok, declarations} <- declarations(body, 0, [], []) do
      Enum.reduce_while(declarations, {:ok, %{}}, fn [name | rest], {:ok, result} ->
        if ascii_upcase(name) in ["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"] do
          {:cont, {:ok, result}}
        else
          top = top_level(rest, 0, [])

          case Enum.drop_while(top, &(ascii_upcase(&1) != "COLLATE")) do
            [] ->
              {:cont, {:ok, Map.put(result, ascii_fold(unquote_name(name)), "BINARY")}}

            [_collate, collation | tail] ->
              collation = collation |> unquote_name() |> ascii_upcase()

              if collation in ["BINARY", "NOCASE", "RTRIM"] and
                   not Enum.any?(tail, &(ascii_upcase(&1) == "COLLATE")),
                 do: {:cont, {:ok, Map.put(result, ascii_fold(unquote_name(name)), collation)}},
                 else: {:halt, :error}

            _ ->
              {:halt, :error}
          end
        end
      end)
    else
      _ -> :error
    end
  end

  defp declarations([")" | _], 0, current, result),
    do: {:ok, Enum.reverse([Enum.reverse(current) | result])}

  defp declarations(["," | tail], 0, current, result),
    do: declarations(tail, 0, [], [Enum.reverse(current) | result])

  defp declarations(["(" = token | tail], depth, current, result),
    do: declarations(tail, depth + 1, [token | current], result)

  defp declarations([")" = token | tail], depth, current, result),
    do: declarations(tail, depth - 1, [token | current], result)

  defp declarations([token | tail], depth, current, result),
    do: declarations(tail, depth, [token | current], result)

  defp declarations([], _depth, _current, _result), do: :error
  defp top_level([], _depth, result), do: Enum.reverse(result)
  defp top_level(["(" | tail], depth, result), do: top_level(tail, depth + 1, result)
  defp top_level([")" | tail], depth, result), do: top_level(tail, depth - 1, result)
  defp top_level([token | tail], 0, result), do: top_level(tail, 0, [token | result])
  defp top_level([_ | tail], depth, result), do: top_level(tail, depth, result)

  defp unquote_name(<<quote, rest::binary>>) when quote in [34, 39, 96] do
    rest
    |> binary_part(0, byte_size(rest) - 1)
    |> String.replace(<<quote, quote>>, <<quote>>)
  end

  defp unquote_name("[" <> rest), do: binary_part(rest, 0, byte_size(rest) - 1)
  defp unquote_name(name), do: name

  # SQLite identifiers fold ASCII letters only. Unicode case pairs are distinct
  # physical names and must never share a column's comparison metadata.
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

  defp denied(code),
    do:
      {:error,
       Error.new(:query_enforcement, "SQLite insert cannot satisfy the captured query guard",
         details: %{code: code, adapter: :sqlite}
       )}
end
