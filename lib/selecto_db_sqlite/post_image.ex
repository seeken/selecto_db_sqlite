defmodule SelectoDBSQLite.PostImage do
  @moduledoc false

  # TW-09 post-image check for guarded INSERT, UPDATE and UPSERT commands
  # (`metadata.post_image`, set by SelectoUpdato: the engine tenant and the
  # trusted and host scope, plus the full guard for an insert).
  #
  # The statement returns the written rows' keys (RETURNING; tagged columns
  # when it returns none itself). After it completes, when every row trigger
  # (SQLite triggers are row-level; AFTER triggers run before the statement
  # returns) and generated column has run, the rows are re-read by key under
  # the scope inside the same transaction. The key must be the relation's
  # INTEGER PRIMARY KEY (its rowid alias), the real rowid when no user column
  # shadows it, or exactly a non-partial unique index over NOT NULL columns.
  # The relation is resolved as SQLite resolves the write's name: temp first,
  # then main; anything else (a view, an attached database) is refused.
  # Unless every written row still matches, the transaction rolls back.

  alias Selecto.Write.{Command, Error}
  alias SelectoDBSQLite.WriteCompiler

  @key_alias "selecto_post_image_key_"
  @rowid ~w(rowid oid _rowid_)

  def prepare(%Command{metadata: %{post_image: %{key: [_ | _]}}, operation: operation} = command)
      when operation in [:insert, :update, :upsert],
      do: {:post_image, command}

  def prepare(command), do: {:plain, command}

  def returning(text, %Command{metadata: %{post_image: %{key: key}}, returning: returning}) do
    if returns_keys?(returning, key) do
      text
    else
      keys =
        key
        |> Enum.with_index(1)
        |> Enum.map_join(", ", fn {column, index} ->
          "#{quote_id(column)} AS #{@key_alias}#{index}"
        end)

      if returning == :none, do: text <> " RETURNING " <> keys, else: text <> ", " <> keys
    end
  end

  defp returns_keys?(:all, _key), do: true

  defp returns_keys?(fields, key) when is_list(fields),
    do: Enum.all?(key, &(&1 in Enum.map(fields, fn field -> to_string(field) end)))

  defp returns_keys?(_returning, _key), do: false

  def split_result(%{columns: columns, rows: rows} = result, %Command{
        metadata: %{post_image: %{key: key}}
      })
      when is_list(columns) and is_list(rows) do
    tagged =
      columns
      |> Enum.with_index()
      |> Enum.filter(fn {column, _index} ->
        String.starts_with?(to_string(column), @key_alias)
      end)
      |> Enum.map(&elem(&1, 1))

    if tagged == [] do
      indexes =
        Enum.map(key, fn column -> Enum.find_index(columns, &(to_string(&1) == column)) end)

      if Enum.any?(indexes, &is_nil/1),
        do: {result, :unknown},
        else: {result, Enum.map(rows, fn row -> Enum.map(indexes, &Enum.at(row, &1)) end)}
    else
      keys = Enum.map(rows, fn row -> Enum.map(tagged, &Enum.at(row, &1)) end)

      keep = fn list ->
        list
        |> Enum.with_index()
        |> Enum.reject(&(elem(&1, 1) in tagged))
        |> Enum.map(&elem(&1, 0))
      end

      result =
        case keep.(columns) do
          [] -> %{result | columns: [], rows: []}
          kept -> %{result | columns: kept, rows: Enum.map(rows, keep)}
        end

      {Map.put(result, :num_rows, length(rows)), keys}
    end
  end

  def split_result(result, _command), do: {result, :unknown}

  def verify(_command, :unknown, _execute, _opts),
    do: refused(:query_rule_not_evaluable, "cannot identify the written rows")

  def verify(%Command{} = command, keys, execute, opts) do
    %{predicate: predicate, key: key} = command.metadata.post_image

    with {:ok, schema, table} <- resolve(command.relation, execute),
         :ok <- keyed(schema, table, key, execute),
         {:ok, scope} <-
           WriteCompiler.compile_predicate(predicate, context: Keyword.get(opts, :context, %{})) do
      relation = "#{quote_id(schema)}.#{quote_id(table)}"
      {match, params} = key_match(key, keys)

      sql =
        "SELECT (SELECT count(*) FROM #{relation} WHERE #{match} AND (#{scope.text})), " <>
          "(SELECT count(*) FROM #{relation} WHERE #{match})"

      case execute.(sql, params ++ scope.params ++ params) do
        {:ok, %{rows: [[matched, rows]]}} ->
          if matched == length(keys) and rows == length(keys),
            do: :ok,
            else: refused(:query_rule_violation, "the written rows left the trusted write scope")

        _ ->
          refused(:query_rule_not_evaluable, "the relation cannot prove the written rows' scope")
      end
    else
      {:error, %Error{}} = error -> error
      _ -> refused(:query_rule_not_evaluable, "the relation cannot prove the written rows' scope")
    end
  end

  # temp shadows main for an unqualified name; a qualified name must be one
  # of the two. Only a table qualifies.
  defp resolve(relation, execute) do
    {schemas, name} =
      case String.split(to_string(relation), ".") do
        [name] -> {["temp", "main"], name}
        [schema, name] when schema in ["main", "temp"] -> {[schema], name}
        _ -> {[], nil}
      end

    Enum.find_value(schemas, :error, fn schema ->
      case execute.(
             "SELECT type, name FROM #{quote_id(schema)}.sqlite_schema WHERE name = ? COLLATE NOCASE AND type IN ('table', 'view')",
             [name]
           ) do
        {:ok, %{rows: [["table", actual]]}} -> {:ok, schema, actual}
        {:ok, %{rows: [_ | _]}} -> :error
        _ -> nil
      end
    end)
  end

  defp keyed(schema, table, key, execute) do
    with {:ok, %{rows: columns}} <-
           execute.("SELECT name, type, \"notnull\", pk FROM pragma_table_info(?, ?)", [
             table,
             schema
           ]) do
      names = Enum.map(columns, fn [name | _] -> String.downcase(name) end)
      key = Enum.map(key, &String.downcase/1)
      pk = for [name, _type, _nn, pk] <- columns, pk > 0, do: String.downcase(name)

      cond do
        # The real rowid, not shadowed by a user column of that name.
        match?([_], key) and hd(key) in @rowid and hd(key) not in names ->
          :ok

        # INTEGER PRIMARY KEY is the rowid alias: unique and never NULL.
        pk == key and match?([_], key) and
            Enum.any?(columns, fn [name, type, _nn, pk] ->
              pk == 1 and String.downcase(name) == hd(key) and
                  String.upcase(to_string(type)) == "INTEGER"
            end) ->
          :ok

        true ->
          unique_index?(schema, table, key, columns, execute)
      end
    end
  end

  defp unique_index?(schema, table, key, columns, execute) do
    not_null =
      for [name, _type, nn, _pk] <- columns, nn == 1, do: String.downcase(name)

    with true <- Enum.all?(key, &(&1 in not_null)),
         {:ok, %{rows: indexes}} <-
           execute.("SELECT name, \"unique\", partial FROM pragma_index_list(?, ?)", [
             table,
             schema
           ]) do
      Enum.find_value(indexes, :error, fn
        [index, 1, 0] ->
          case execute.("SELECT name FROM pragma_index_info(?, ?)", [index, schema]) do
            {:ok, %{rows: rows}} ->
              names = Enum.map(rows, fn [name] -> name && String.downcase(name) end)
              if Enum.sort(names) == Enum.sort(key), do: :ok

            _ ->
              nil
          end

        _ ->
          nil
      end)
    else
      _ -> :error
    end
  end

  defp key_match([column], keys) do
    case keys do
      [] ->
        {"0", []}

      keys ->
        {"#{quote_id(column)} IN (#{Enum.map_join(keys, ", ", fn _ -> "?" end)})",
         Enum.map(keys, &hd/1)}
    end
  end

  defp key_match(columns, keys) do
    case keys do
      [] ->
        {"0", []}

      keys ->
        row = "(" <> Enum.map_join(columns, " AND ", &"#{quote_id(&1)} = ?") <> ")"
        {"(" <> Enum.map_join(keys, " OR ", fn _ -> row end) <> ")", List.flatten(keys)}
    end
  end

  defp refused(code, message),
    do:
      {:error,
       Error.new(:query_enforcement, "SQLite " <> message,
         details: %{code: code, adapter: :sqlite}
       )}

  defp quote_id(identifier),
    do: "\"" <> String.replace(to_string(identifier), "\"", "\"\"") <> "\""
end
