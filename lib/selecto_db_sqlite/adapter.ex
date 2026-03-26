defmodule SelectoDBSQLite.Adapter do
  @moduledoc """
  SQLite adapter for Selecto backed by `Exqlite`.
  """

  @behaviour Selecto.DB.Adapter

  @missing_dependency {:adapter_dependency_missing, :exqlite}
  @transaction_depth_key {__MODULE__, :transaction_depth}
  @supported_features [
    :cte,
    :json_rowset,
    :sqlite_upsert,
    :window_functions,
    :transactions,
    :schema_introspection
  ]

  @impl true
  def name, do: :sqlite

  @impl true
  def connect(connection) when is_reference(connection), do: {:ok, connection}
  def connect(connection) when is_map(connection), do: connect(Map.to_list(connection))

  def connect(opts) when is_list(opts) do
    if dependency_available?() do
      database = Keyword.get(opts, :database) || Keyword.get(opts, :path) || ":memory:"
      mode = Keyword.get(opts, :mode, :readwrite)

      case Exqlite.Sqlite3.open(database, mode: mode) do
        {:ok, conn} -> {:ok, conn}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, @missing_dependency}
    end
  end

  def connect(other), do: {:error, {:invalid_connection_options, other}}

  @impl true
  def execute(connection, query, params, _opts) do
    resolved_connection = resolve_connection(connection)

    cond do
      not dependency_available?() ->
        {:error, @missing_dependency}

      not is_reference(resolved_connection) ->
        {:error, {:invalid_connection, connection}}

      true ->
        execute_statement(resolved_connection, normalize_query(query), params || [])
    end
  end

  @impl true
  def execute_raw(connection, query, params) do
    execute(connection, query, params, [])
  end

  @impl true
  def placeholder(_index), do: "?"

  @impl true
  def quote_identifier(identifier) when is_binary(identifier) do
    escaped = String.replace(identifier, "\"", "\"\"")
    "\"#{escaped}\""
  end

  def quote_identifier(identifier), do: identifier |> to_string() |> quote_identifier()

  @impl true
  def supports?(feature) do
    feature in @supported_features
  end

  @impl true
  def list_tables(connection, _opts \\ []) do
    query = """
    SELECT name
    FROM sqlite_master
    WHERE type = 'table'
      AND name NOT LIKE 'sqlite_%'
    ORDER BY name
    """

    case introspection_query(connection, query, []) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [table_name] -> table_name end)}
      {:error, reason} -> {:error, {:query_failed, reason}}
    end
  end

  @impl true
  def introspect_table(connection, table_name, opts \\ []) do
    include_associations = Keyword.get(opts, :include_associations, true)
    expand = Keyword.get(opts, :expand, false)

    with {:ok, columns} <- get_columns(connection, table_name),
         {:ok, primary_key} <- get_primary_key(columns),
         {:ok, foreign_keys} <- get_foreign_keys(connection, table_name) do
      fields = Enum.map(columns, & &1.column_name)

      field_types =
        Enum.into(columns, %{}, fn column ->
          {column.column_name, map_sqlite_type(column.data_type)}
        end)

      associations =
        cond do
          not include_associations ->
            %{}

          expand ->
            case build_expanded_associations(connection, table_name, primary_key) do
              {:ok, expanded_associations} -> expanded_associations
              {:error, _reason} -> build_associations(foreign_keys)
            end

          true ->
            build_associations(foreign_keys)
        end

      column_metadata =
        Enum.into(columns, %{}, fn column ->
          {column.column_name,
           %{
             type: Map.get(field_types, column.column_name),
             nullable: column.nullable,
             default: column.default,
             max_length: nil,
             precision: nil,
             scale: nil
           }}
        end)

      {:ok,
       %{
         table_name: table_name,
         schema: "main",
         fields: fields,
         field_types: field_types,
         primary_key: primary_key,
         associations: associations,
         columns: column_metadata,
         source: :sqlite
       }}
    end
  end

  @impl true
  def validate_connection(connection) do
    resolved_connection = resolve_connection(connection)

    cond do
      not dependency_available?() ->
        {:error, @missing_dependency}

      is_reference(resolved_connection) ->
        case execute(resolved_connection, "SELECT 1", [], []) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:connection_unhealthy, reason}}
        end

      true ->
        {:error, {:invalid_connection, connection}}
    end
  end

  @impl true
  def connection_info(connection) do
    resolved_connection = resolve_connection(connection)

    cond do
      is_reference(resolved_connection) ->
        case validate_connection(resolved_connection) do
          :ok ->
            %{type: :sqlite, connection: :exqlite, status: :connected}

          {:error, reason} ->
            %{type: :sqlite, connection: :exqlite, status: :disconnected, reason: reason}
        end

      true ->
        %{type: :sqlite, status: :invalid, value: connection}
    end
  end

  @impl true
  def transaction(connection, fun, _opts \\ []) when is_function(fun, 1) do
    resolved_connection = resolve_connection(connection)
    depth = transaction_depth_for(resolved_connection)
    begin_sql = if depth == 0, do: "BEGIN", else: "SAVEPOINT #{savepoint_name(depth + 1)}"

    with :ok <- validate_connection(resolved_connection),
         {:ok, _} <- execute(resolved_connection, begin_sql, [], []) do
      put_transaction_depth(resolved_connection, depth + 1)
      execute_transaction_fun(resolved_connection, fun, depth + 1)
    end
  end

  defp execute_transaction_fun(connection, fun, depth) do
    case fun.(connection) do
      {:error, reason} ->
        rollback(connection, depth, reason)

      result ->
        case finalize_commit(connection, depth) do
          :ok -> {:ok, result}
          {:error, reason} -> rollback(connection, depth, reason)
        end
    end
  rescue
    error ->
      rollback(connection, depth, error)
  catch
    kind, reason ->
      rollback(connection, depth, {kind, reason})
  after
    put_transaction_depth(connection, max(depth - 1, 0))
  end

  defp finalize_commit(connection, 1) do
    case execute(connection, "COMMIT", [], []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp finalize_commit(connection, depth) when depth > 1 do
    case execute(connection, "RELEASE SAVEPOINT #{savepoint_name(depth)}", [], []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback(connection, 1, reason) do
    _ = execute(connection, "ROLLBACK", [], [])
    {:error, reason}
  end

  defp rollback(connection, depth, reason) when depth > 1 do
    savepoint = savepoint_name(depth)
    _ = execute(connection, "ROLLBACK TO SAVEPOINT #{savepoint}", [], [])
    _ = execute(connection, "RELEASE SAVEPOINT #{savepoint}", [], [])
    {:error, reason}
  end

  defp savepoint_name(depth), do: "selecto_sp_#{depth}"

  defp transaction_depth_for(connection) do
    transaction_depths = Process.get(@transaction_depth_key, %{})
    Map.get(transaction_depths, connection, 0)
  end

  defp put_transaction_depth(connection, depth) do
    transaction_depths = Process.get(@transaction_depth_key, %{})

    updated_depths =
      if depth <= 0 do
        Map.delete(transaction_depths, connection)
      else
        Map.put(transaction_depths, connection, depth)
      end

    Process.put(@transaction_depth_key, updated_depths)
    :ok
  end

  defp execute_statement(connection, query, params) do
    case Exqlite.Sqlite3.prepare(connection, query) do
      {:ok, statement} ->
        result =
          with :ok <- bind_params(statement, params),
               {:ok, columns} <- Exqlite.Sqlite3.columns(connection, statement),
               {:ok, rows} <- Exqlite.Sqlite3.fetch_all(connection, statement) do
            {:ok,
             %{
               rows: rows || [],
               columns: Enum.map(columns || [], &to_string/1)
             }}
          end

        _ = Exqlite.Sqlite3.release(connection, statement)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp introspection_query(%{query_fun: query_fun}, query, params)
       when is_function(query_fun, 3) do
    query_fun.(query, params, prepared: false)
  end

  defp introspection_query(connection, query, params) do
    execute(connection, query, params, [])
  end

  defp get_columns(connection, table_name) do
    query = "PRAGMA table_info(\"#{escape_sqlite_identifier(table_name)}\")"

    case introspection_query(connection, query, []) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [cid, column_name, data_type, notnull, default_value, pk] ->
           %{
             cid: cid,
             column_name: String.to_atom(column_name),
             data_type: data_type || "",
             nullable: notnull == 0,
             default: default_value,
             pk: pk
           }
         end)}

      {:error, reason} ->
        {:error, {:columns_query_failed, reason}}
    end
  end

  defp get_primary_key(columns) do
    primary_keys =
      columns
      |> Enum.filter(&(&1.pk && &1.pk > 0))
      |> Enum.sort_by(& &1.pk)
      |> Enum.map(& &1.column_name)

    case primary_keys do
      [] -> {:ok, nil}
      [single] -> {:ok, single}
      keys -> {:ok, keys}
    end
  end

  defp get_foreign_keys(connection, table_name) do
    query = "PRAGMA foreign_key_list(\"#{escape_sqlite_identifier(table_name)}\")"

    case introspection_query(connection, query, []) do
      {:ok, %{rows: rows}} ->
        grouped_rows = Enum.group_by(rows, fn [id | _rest] -> id end)

        {:ok,
         Enum.map(grouped_rows, fn {id, [row | _]} ->
           [_id, _seq, foreign_table, column_name, foreign_column_name | _rest] = row

           %{
             constraint_name: "fk_#{table_name}_#{id}",
             column_name: String.to_atom(column_name),
             foreign_table_schema: "main",
             foreign_table_name: foreign_table,
             foreign_column_name: String.to_atom(foreign_column_name || "id")
           }
         end)}

      {:error, reason} ->
        {:error, {:foreign_keys_query_failed, reason}}
    end
  end

  defp get_reverse_foreign_keys(connection, table_name) do
    with {:ok, tables} <- list_tables(connection),
         rows <-
           Enum.flat_map(tables, fn candidate_table ->
             case get_foreign_keys(connection, candidate_table) do
               {:ok, foreign_keys} ->
                 foreign_keys
                 |> Enum.filter(&(&1.foreign_table_name == table_name))
                 |> Enum.map(fn foreign_key ->
                   %{
                     referencing_table: candidate_table,
                     referencing_column: foreign_key.column_name,
                     referenced_column: foreign_key.foreign_column_name,
                     constraint_name: foreign_key.constraint_name
                   }
                 end)

               {:error, _reason} ->
                 []
             end
           end) do
      {:ok, rows}
    end
  end

  defp build_associations(foreign_keys) do
    Enum.into(foreign_keys, %{}, fn foreign_key ->
      association_name =
        foreign_key.column_name
        |> Atom.to_string()
        |> String.replace_suffix("_id", "")
        |> String.to_atom()

      related_module_name = table_name_to_module(foreign_key.foreign_table_name)

      {association_name,
       %{
         type: :belongs_to,
         association_type: :belongs_to,
         related_schema: related_module_name,
         related_module_name: related_module_name,
         related_table: foreign_key.foreign_table_name,
         queryable: String.to_atom(foreign_key.foreign_table_name),
         field: association_name,
         owner_key: foreign_key.column_name,
         related_key: foreign_key.foreign_column_name,
         join_type: :inner,
         is_through: false,
         constraint_name: foreign_key.constraint_name
       }}
    end)
  end

  defp build_expanded_associations(connection, table_name, primary_key) do
    with {:ok, foreign_keys} <- get_foreign_keys(connection, table_name),
         {:ok, reverse_foreign_keys} <- get_reverse_foreign_keys(connection, table_name),
         {:ok, junction_tables} <- detect_junction_tables(connection) do
      belongs_to = build_associations(foreign_keys)
      primary_key_field = normalize_primary_key(primary_key)

      has_many =
        Enum.into(reverse_foreign_keys, %{}, fn reverse_foreign_key ->
          association_name = String.to_atom(reverse_foreign_key.referencing_table)
          related_module_name = table_name_to_module(reverse_foreign_key.referencing_table)

          {association_name,
           %{
             type: :has_many,
             association_type: :has_many,
             related_schema: related_module_name,
             related_module_name: related_module_name,
             related_table: reverse_foreign_key.referencing_table,
             queryable: String.to_atom(reverse_foreign_key.referencing_table),
             field: association_name,
             owner_key: primary_key_field,
             related_key: reverse_foreign_key.referencing_column,
             join_type: :left,
             is_through: false,
             constraint_name: reverse_foreign_key.constraint_name
           }}
        end)

      many_to_many =
        junction_tables
        |> Enum.filter(fn junction -> table_name in junction.tables end)
        |> Enum.flat_map(fn junction ->
          {this_foreign_keys, other_foreign_keys} =
            Enum.split_with(junction.foreign_keys, fn foreign_key ->
              foreign_key.foreign_table_name == table_name
            end)

          Enum.map(other_foreign_keys, fn other_foreign_key ->
            association_name = String.to_atom(other_foreign_key.foreign_table_name)
            related_module_name = table_name_to_module(other_foreign_key.foreign_table_name)

            owner_foreign_key =
              case this_foreign_keys do
                [foreign_key | _] -> foreign_key.column_name
                _ -> primary_key_field
              end

            {association_name,
             %{
               type: :many_to_many,
               association_type: :many_to_many,
               related_schema: related_module_name,
               related_module_name: related_module_name,
               related_table: other_foreign_key.foreign_table_name,
               queryable: String.to_atom(other_foreign_key.foreign_table_name),
               field: association_name,
               owner_key: primary_key_field,
               related_key: other_foreign_key.foreign_column_name,
               join_type: :left,
               is_through: false,
               join_through: junction.table,
               join_keys: [
                 {owner_foreign_key, primary_key_field},
                 {other_foreign_key.column_name, other_foreign_key.foreign_column_name}
               ]
             }}
          end)
        end)
        |> Enum.into(%{})

      {:ok, belongs_to |> Map.merge(has_many) |> Map.merge(many_to_many)}
    end
  end

  defp detect_junction_tables(connection) do
    with {:ok, tables} <- list_tables(connection) do
      junction_tables =
        Enum.flat_map(tables, fn table ->
          case analyze_junction_table(connection, table) do
            {:ok, junction_table} -> [junction_table]
            _ -> []
          end
        end)

      {:ok, junction_tables}
    end
  end

  defp analyze_junction_table(connection, table) do
    with {:ok, columns} <- get_columns(connection, table),
         {:ok, foreign_keys} <- get_foreign_keys(connection, table),
         {:ok, primary_key} <- get_primary_key(columns),
         true <- junction_table?(columns, foreign_keys) do
      primary_key_fields = normalize_primary_keys(primary_key)
      foreign_key_fields = Enum.map(foreign_keys, & &1.column_name)
      all_fields = Enum.map(columns, & &1.column_name)

      {:ok,
       %{
         table: table,
         foreign_keys: foreign_keys,
         primary_key: primary_key,
         extra_columns: all_fields -- Enum.uniq(primary_key_fields ++ foreign_key_fields),
         tables: Enum.map(foreign_keys, & &1.foreign_table_name)
       }}
    else
      false -> {:error, :not_junction_table}
      {:error, reason} -> {:error, reason}
    end
  end

  defp junction_table?(columns, foreign_keys) do
    foreign_key_fields = MapSet.new(Enum.map(foreign_keys, & &1.column_name))

    data_fields =
      columns
      |> Enum.map(& &1.column_name)
      |> Enum.reject(fn field ->
        field_name = Atom.to_string(field)

        field_name in ["id", "inserted_at", "updated_at", "created_at"] or
          String.ends_with?(field_name, "_at")
      end)

    length(foreign_keys) == 2 and Enum.all?(data_fields, &MapSet.member?(foreign_key_fields, &1))
  end

  defp normalize_primary_key([primary_key | _]), do: primary_key
  defp normalize_primary_key(primary_key) when is_atom(primary_key), do: primary_key
  defp normalize_primary_key(_), do: :id

  defp normalize_primary_keys(primary_key) when is_list(primary_key), do: primary_key
  defp normalize_primary_keys(primary_key) when is_atom(primary_key), do: [primary_key]
  defp normalize_primary_keys(_), do: []

  defp map_sqlite_type(data_type) when is_binary(data_type) do
    normalized = String.upcase(data_type)

    cond do
      String.contains?(normalized, "INT") ->
        :integer

      String.contains?(normalized, "CHAR") or String.contains?(normalized, "CLOB") or
          String.contains?(normalized, "TEXT") ->
        :string

      String.contains?(normalized, "BLOB") ->
        :binary

      String.contains?(normalized, "REAL") or String.contains?(normalized, "FLOA") or
          String.contains?(normalized, "DOUB") ->
        :float

      String.contains?(normalized, "NUM") or String.contains?(normalized, "DEC") ->
        :decimal

      String.contains?(normalized, "BOOL") ->
        :boolean

      String.contains?(normalized, "DATE") and String.contains?(normalized, "TIME") ->
        :naive_datetime

      String.contains?(normalized, "DATE") ->
        :date

      String.contains?(normalized, "TIME") ->
        :time

      true ->
        :string
    end
  end

  defp map_sqlite_type(_data_type), do: :string

  defp table_name_to_module(table_name) when is_binary(table_name) do
    table_name
    |> singularize()
    |> Macro.camelize()
  end

  defp singularize(word) do
    cond do
      String.ends_with?(word, "ies") ->
        String.replace_suffix(word, "ies", "y")

      String.ends_with?(word, "sses") ->
        String.replace_suffix(word, "sses", "ss")

      String.ends_with?(word, "ses") ->
        String.replace_suffix(word, "ses", "s")

      String.ends_with?(word, "s") and not String.ends_with?(word, "ss") ->
        String.replace_suffix(word, "s", "")

      true ->
        word
    end
  end

  defp escape_sqlite_identifier(identifier), do: String.replace(identifier, "\"", "\"\"")

  defp bind_params(statement, params) do
    try do
      :ok = Exqlite.Sqlite3.bind(statement, params)
      :ok
    rescue
      error in ArgumentError -> {:error, {:invalid_query_params, Exception.message(error)}}
    end
  end

  defp resolve_connection(%{adapter: _adapter, connection: nested_connection}) do
    resolve_connection(nested_connection)
  end

  defp resolve_connection(%{db: db}) when is_reference(db), do: db
  defp resolve_connection(connection), do: connection

  defp normalize_query(query) when is_binary(query), do: query
  defp normalize_query(query), do: IO.iodata_to_binary(query)

  defp dependency_available? do
    Code.ensure_loaded?(Exqlite.Sqlite3) and function_exported?(Exqlite.Sqlite3, :open, 2) and
      function_exported?(Exqlite.Sqlite3, :prepare, 2) and
      function_exported?(Exqlite.Sqlite3, :bind, 2) and
      function_exported?(Exqlite.Sqlite3, :columns, 2) and
      function_exported?(Exqlite.Sqlite3, :fetch_all, 2) and
      function_exported?(Exqlite.Sqlite3, :release, 2)
  end
end
