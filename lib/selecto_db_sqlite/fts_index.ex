defmodule SelectoDBSQLite.FtsIndex do
  @moduledoc false
  alias Selecto.Domain.Shared.Map, as: DomainMap
  alias SelectoDBSQLite.{Adapter, QueryGuard}

  def declared?(selecto), do: not is_nil(DomainMap.map_value(source(selecto), :fts5_index))

  # This proof is deliberately connection-local and uncached. Native PRAGMAs
  # cannot be replaced by a table named pragma_table_list/table_xinfo, and the
  # identity comparison never invokes a host-supplied SQLite collation.
  def verify(selecto, fields) do
    connection = Selecto.Runtime.Context.connection(selecto)

    if is_reference(connection) or
         (is_map(connection) and is_reference(Map.get(connection, :connection))) do
      QueryGuard.run(connection, fn -> prove(connection, selecto, fields) end)
    else
      error("SQLite external FTS5 search requires a connected catalog proof")
    end
  rescue
    _ -> error("SQLite FTS5 catalog could not be inspected")
  end

  def query(text, :prefix) when is_binary(text) and byte_size(text) <= 4096 do
    if Regex.match?(~r/\A[\p{L}\p{N}_]+:\*(?: & [\p{L}\p{N}_]+:\*)*\z/u, text),
      do: {:ok, ["replace(replace(", {:param, text}, ", ':*', '*'), ' & ', ' AND ')"]},
      else: error("SQLite prefix search requires normalized word prefixes")
  end

  def query(text, :plain) when is_binary(text) and byte_size(text) <= 4096 do
    terms = Regex.scan(~r/[\p{L}\p{N}_]+/u, text) |> List.flatten()

    if terms == [],
      do: error("SQLite plain search requires words"),
      else: {:ok, {:param, Enum.map_join(terms, " AND ", &quote_term/1)}}
  end

  def query(text, :phrase) when is_binary(text) and byte_size(text) <= 4096,
    do: {:ok, {:param, quote_term(text)}}

  def query(text, mode)
      when is_binary(text) and byte_size(text) <= 4096 and mode in [:websearch, :boolean, nil],
      do: {:ok, {:param, text}}

  def query(_text, _mode), do: error("SQLite FTS5 search text or mode is unavailable")

  def match_query(fields, query) do
    restriction = "{" <> Enum.join(fields, " ") <> "}:("
    ["('", restriction, "' || ", query, " || ')')"]
  end

  defp prove(connection, selecto, fields) do
    root = source(selecto)
    declaration = DomainMap.map_value(root, :fts5_index)
    table = DomainMap.map_value(declaration, :table)
    key = DomainMap.map_value(declaration, :key)
    content = DomainMap.map_value(root, :source_table)

    with true <- is_map(declaration) and map_size(declaration) == 2,
         true <- Enum.sort(Enum.map(Map.keys(declaration), &to_string/1)) == ["key", "table"],
         true <- Enum.all?([table, key, content], &identifier?/1),
         true <- to_string(key) == to_string(DomainMap.map_value(root, :primary_key)),
         {:ok, search_fields} <- fields(selecto, fields),
         {:ok, root_ddl} <- catalog(connection, to_string(content), "table"),
         true <- is_binary(root_ddl),
         {:ok, [[_, _, "table", _, 0, _]]} <- native_table(connection, to_string(content)),
         {:ok, root_columns} <-
           rows(connection, "PRAGMA main.table_xinfo('" <> to_string(content) <> "')"),
         true <- valid_key?(root_columns, to_string(key)),
         {:ok, root_indexes} <-
           rows(connection, "PRAGMA main.index_list('" <> to_string(content) <> "')"),
         true <- rowid_alias?(root_indexes),
         true <- stored_text?(root_columns, search_fields),
         true <- domain_key?(root, key),
         {:ok, ddl} <- catalog(connection, to_string(table), "table"),
         {:ok, [[_, _, "virtual", _, 0, _]]} <- native_table(connection, to_string(table)),
         {:ok, indexed, options} <- declaration(ddl),
         true <-
           options["content"] == to_string(content) and options["content_rowid"] == to_string(key),
         true <- String.downcase(Map.get(options, "tokenize", "unicode61")) == "unicode61",
         true <- String.downcase(Map.get(options, "detail", "full")) == "full",
         true <- Enum.all?(search_fields, &(&1 in indexed)) do
      {:ok, %{table: to_string(table), key: to_string(key), fields: search_fields}}
    else
      {:error, _} = error ->
        error

      _ ->
        error(
          "SQLite external FTS5 index does not match the stored root identity and text fields"
        )
    end
  end

  defp fields(selecto, fields) do
    result =
      Enum.map(fields, fn field ->
        name = if is_map(field), do: field.name, else: to_string(field)
        conf = if is_map(field), do: field.config, else: Selecto.field(selecto, name)

        authored =
          case DomainMap.fetch_key(DomainMap.map_value(source(selecto), :columns) || %{}, name) do
            {:ok, definition} when is_map(definition) -> definition
            _ -> %{}
          end

        valid =
          is_map(conf) and Map.get(conf, :requires_join, :selecto_root) == :selecto_root and
            Map.get(conf, :type) in [:string, "string"] and Map.get(conf, :internal) != true and
            not Map.has_key?(conf, :computed) and identifier?(name) and
            DomainMap.map_value(authored, :type) in [:string, "string"] and
            DomainMap.map_value(authored, :internal) != true and
            not Map.has_key?(authored, :computed) and not Map.has_key?(authored, "computed")

        if valid, do: {:ok, name}, else: :error
      end)

    if result != [] and length(result) <= 128 and Enum.all?(result, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(result, &elem(&1, 1))},
      else: error("SQLite external FTS5 search requires public stored root text fields")
  end

  defp domain_key?(root, key) do
    conf =
      case DomainMap.fetch_key(DomainMap.map_value(root, :columns) || %{}, key) do
        {:ok, definition} when is_map(definition) -> definition
        _ -> %{}
      end

    DomainMap.map_value(conf, :type) in [:integer, "integer"] and
      DomainMap.map_value(conf, :internal) != true and not Map.has_key?(conf, :computed) and
      not Map.has_key?(conf, "computed")
  end

  defp valid_key?(columns, key) do
    case Enum.filter(columns, fn [_, _, _, _, _, pk, _] -> pk > 0 end) do
      [[_, ^key, type, _, _, 1, 0]] -> String.upcase(type) == "INTEGER"
      _ -> false
    end
  end

  defp stored_text?(columns, fields) do
    Enum.all?(fields, fn name ->
      Enum.any?(columns, fn
        [_, ^name, type, _, _, _, 0] -> text_affinity?(type)
        _ -> false
      end)
    end)
  end

  # INTEGER PRIMARY KEY DESC creates a separate primary-key index and admits
  # NULL keys. An ordinary sole INTEGER key is a rowid alias only when native
  # SQLite reports no primary-key index (table-level DESC still aliases rowid).
  defp rowid_alias?(indexes),
    do:
      Enum.all?(indexes, fn
        [_, _, _, origin, _] -> origin != "pk"
        _ -> false
      end)

  defp text_affinity?(type) do
    type = String.upcase(type)

    not String.contains?(type, "INT") and
      Enum.any?(["CHAR", "CLOB", "TEXT"], &String.contains?(type, &1))
  end

  defp catalog(connection, table, type) do
    with {:ok, main} <-
           rows(connection, "SELECT name,type,sql FROM main.sqlite_schema LIMIT 4097"),
         {:ok, temp} <-
           rows(connection, "SELECT name,type,sql FROM temp.sqlite_schema LIMIT 4097"),
         [] <- Enum.filter(temp, fn [name, _, _] -> identity?(name, table) end),
         [[_, ^type, ddl]] <- Enum.filter(main, fn [name, _, _] -> identity?(name, table) end),
         true <- is_binary(ddl) and byte_size(ddl) <= 16384 do
      {:ok, ddl}
    else
      _ -> error("SQLite FTS5 source has missing or ambiguous main catalog identity")
    end
  end

  defp native_table(connection, table) do
    with {:ok, result} <- rows(connection, "PRAGMA main.table_list('" <> table <> "')") do
      {:ok,
       Enum.filter(result, fn [schema, name | _] ->
         schema == "main" and identity?(name, table)
       end)}
    end
  end

  defp rows(connection, sql) do
    case Adapter.execute(connection, sql, [], []) do
      {:ok, %{rows: rows}} when length(rows) <= 4096 -> {:ok, rows}
      _ -> error("SQLite FTS5 catalog could not be inspected within its bound")
    end
  end

  # A bounded subset of the native CREATE VIRTUAL TABLE syntax. Quoted commas
  # are retained; unsupported comments, options and malformed quoting refuse.
  defp declaration(ddl) do
    case Regex.run(~r/\A\s*CREATE\s+VIRTUAL\s+TABLE\s+.+?\s+USING\s+fts5\s*\((.*)\)\s*\z/is, ddl,
           capture: :all_but_first
         ) do
      [arguments] ->
        with {:ok, args} <- split_arguments(String.to_charlist(arguments), [], [], nil),
             true <- length(args) <= 128 do
          Enum.reduce_while(args, {:ok, [], %{}}, &parse_argument/2)
        else
          _ -> error("SQLite FTS5 declaration is unavailable")
        end

      _ ->
        error("SQLite text search requires a supplied FTS5 virtual table")
    end
  end

  defp split_arguments([], current, parts, nil),
    do:
      {:ok,
       Enum.reverse([current |> Enum.reverse() |> List.to_string() |> String.trim() | parts])}

  defp split_arguments([], _current, _parts, _quote), do: :error

  defp split_arguments([quote, quote | rest], current, parts, quote) when not is_nil(quote),
    do: split_arguments(rest, [quote, quote | current], parts, quote)

  defp split_arguments([quote | rest], current, parts, quote) when not is_nil(quote),
    do: split_arguments(rest, [quote | current], parts, nil)

  defp split_arguments([char | rest], current, parts, quote) when not is_nil(quote),
    do: split_arguments(rest, [char | current], parts, quote)

  defp split_arguments([char | rest], current, parts, nil) when char in [?\", ?', ?`],
    do: split_arguments(rest, [char | current], parts, char)

  defp split_arguments([?, | rest], current, parts, nil),
    do:
      split_arguments(
        rest,
        [],
        [current |> Enum.reverse() |> List.to_string() |> String.trim() | parts],
        nil
      )

  defp split_arguments([char | rest], current, parts, nil),
    do: split_arguments(rest, [char | current], parts, nil)

  defp parse_argument(arg, {:ok, columns, options}) do
    case String.split(arg, "=", parts: 2) do
      [name, value] ->
        key = String.downcase(String.trim(name))

        with true <- key in ["content", "content_rowid", "tokenize", "detail"],
             false <- Map.has_key?(options, key),
             {:ok, atom} <- identifier_atom(value) do
          {:cont, {:ok, columns, Map.put(options, key, atom)}}
        else
          _ -> {:halt, error("SQLite FTS5 index option is unavailable or ambiguous")}
        end

      [column] ->
        unindexed? = Regex.match?(~r/\s+UNINDEXED\s*\z/i, column)
        name = Regex.replace(~r/\s+UNINDEXED\s*\z/i, column, "")

        case identifier_atom(name) do
          {:ok, name} ->
            {:cont, {:ok, if(unindexed?, do: columns, else: columns ++ [name]), options}}

          _ ->
            {:halt, error("SQLite FTS5 indexed column declaration is unavailable")}
        end
    end
  end

  defp identifier_atom(raw) do
    value = String.trim(raw)

    value =
      case String.to_charlist(value) do
        [quote | _] when quote in [?\", ?', ?`] ->
          delimiter = <<quote>>

          if String.ends_with?(value, delimiter) and byte_size(value) >= 2,
            do: binary_part(value, 1, byte_size(value) - 2),
            else: ""

        _ ->
          value
      end

    if identifier?(value), do: {:ok, value}, else: :error
  end

  defp identifier?(value) when is_atom(value) or is_binary(value),
    do: Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, to_string(value))

  defp identifier?(_value), do: false
  defp identity?(left, right), do: String.downcase(left, :ascii) == String.downcase(right, :ascii)
  defp source(selecto), do: DomainMap.map_value(selecto.domain, :source) || %{}
  defp quote_term(text), do: "\"" <> String.replace(text, "\"", "\"\"") <> "\""

  defp error(message),
    do: {:error, Selecto.Error.validation_error(message, %{unsupported_feature: :text_search})}
end
