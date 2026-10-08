defmodule SelectoDBSQLite.Introspection do
  @moduledoc false

  alias SelectoDBSQLite.Adapter

  def list_tables(connection, opts) do
    with {:ok, relations} <- list_relations(connection, opts) do
      {:ok, for(%{kind: :table, name: name} <- relations, do: name)}
    end
  end

  def list_relations(connection, opts) do
    schema = Keyword.get(opts, :schema, "main")

    query =
      "SELECT name, type, sql FROM #{Adapter.quote_identifier(schema)}.sqlite_master " <>
        "WHERE type IN ('table', 'view') AND substr(name, 1, 7) <> 'sqlite_' ORDER BY name"

    with {:ok, %{rows: rows}} <- Adapter.execute(connection, query, [], opts) do
      {:ok,
       Enum.map(rows, fn [name, type, sql] ->
         %{
           name: name,
           table_name: name,
           schema: schema,
           kind: if(type == "view", do: :view, else: :table),
           definition: sql
         }
       end)}
    end
  end

  def introspect_table(connection, table, opts) do
    schema = Keyword.get(opts, :schema, "main")

    with {:ok, %{rows: columns}} <- pragma(connection, schema, "table_xinfo", table, opts),
         :ok <- require_table(columns, table),
         {:ok, %{rows: keys}} <- pragma(connection, schema, "foreign_key_list", table, opts),
         {:ok, %{rows: indexes}} <- pragma(connection, schema, "index_list", table, opts),
         {:ok, indexes} <- describe_indexes(connection, schema, indexes, opts) do
      visible =
        Enum.reject(columns, fn [_cid, _name, _type, _notnull, _default, _pk, hidden] ->
          hidden == 1
        end)

      field_types =
        Map.new(visible, fn [_cid, name, type | _] -> {name, Adapter.normalize_type(type)} end)

      primary_keys =
        visible
        |> Enum.filter(fn [_cid, _name, _type, _notnull, _default, pk, _hidden] -> pk > 0 end)
        |> Enum.sort_by(fn [_cid, _name, _type, _notnull, _default, pk, _hidden] -> pk end)
        |> Enum.map(fn [_cid, name | _] -> Selecto.Identifier.to_atom!(name) end)

      metadata =
        Map.new(visible, fn [_cid, name, declaration, notnull, default, pk, hidden] ->
          {name,
           %{
             type: Map.fetch!(field_types, name),
             declared_type: declaration,
             nullable: notnull == 0,
             default: default,
             primary_key_position: pk,
             generated: hidden in [2, 3]
           }}
        end)

      {:ok,
       %{
         table_name: table,
         schema: schema,
         source: :sqlite,
         fields: Enum.map(visible, fn [_cid, name | _] -> name end),
         field_types: field_types,
         primary_key: primary_key(primary_keys),
         columns: metadata,
         associations: %{},
         foreign_keys: Enum.map(keys, &foreign_key/1),
         indexes: indexes
       }}
    end
  end

  def analyze_query(selecto, opts) do
    if Keyword.get(opts, :analyze, false) do
      {:error,
       Selecto.Error.validation_error("SQLite provides query plans without EXPLAIN ANALYZE", %{
         adapter: :sqlite,
         unsupported_feature: :explain_analyze
       })}
    else
      {query, params} = Selecto.to_sql(selecto, Keyword.get(opts, :to_sql_opts, []))
      sql = "EXPLAIN QUERY PLAN " <> query
      connection = Selecto.Runtime.Context.connection(selecto)

      with {:ok, %{rows: rows, columns: columns}} <-
             Adapter.execute(connection, sql, params, opts) do
        {:ok,
         %{
           query_sql: query,
           explain_sql: sql,
           params: params,
           columns: columns,
           rows: rows,
           plan_lines: Enum.map(rows, &List.last/1),
           dialect: :sqlite,
           analyze: false,
           plan:
             Enum.map(rows, fn [id, parent, _unused, detail] ->
               %{id: id, parent: parent, detail: detail}
             end)
         }}
      end
    end
  end

  defp pragma(connection, schema, operation, target, opts),
    do:
      Adapter.execute(
        connection,
        "PRAGMA #{Adapter.quote_identifier(schema)}.#{operation}(#{Adapter.quote_identifier(target)})",
        [],
        opts
      )

  defp require_table([], table), do: {:error, {:sqlite_relation_not_found, table}}
  defp require_table(_columns, _table), do: :ok
  defp primary_key([]), do: nil
  defp primary_key([key]), do: key
  defp primary_key(keys), do: keys

  defp foreign_key([id, sequence, target, from, to, on_update, on_delete, match]),
    do: %{
      id: id,
      sequence: sequence,
      foreign_table_name: target,
      column_name: from,
      foreign_column_name: to,
      on_update: on_update,
      on_delete: on_delete,
      match: match
    }

  defp describe_indexes(connection, schema, indexes, opts) do
    Enum.reduce_while(indexes, {:ok, []}, fn [_seq, name, unique, origin, partial],
                                             {:ok, described} ->
      case pragma(connection, schema, "index_xinfo", name, opts) do
        {:ok, %{rows: columns}} ->
          index = %{
            name: name,
            unique: unique == 1,
            origin: origin,
            partial: partial == 1,
            columns:
              for(
                [position, cid, column, descending, collation, 1] <- columns,
                do: %{
                  position: position,
                  column: column,
                  expression: cid == -2,
                  descending: descending == 1,
                  collation: collation
                }
              )
          }

          {:cont, {:ok, described ++ [index]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end
end
