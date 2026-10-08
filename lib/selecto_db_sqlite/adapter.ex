defmodule SelectoDBSQLite.Adapter do
  @moduledoc """
  SQLite adapter for Selecto backed by Exqlite.

  Writes reach this adapter through the governed entry point, `SelectoUpdato`.
  `execute_write/3` and `execute_prepared_write/3` refuse a write without the
  `Selecto.Write.Authorization` issued for exactly that payload
  (`:ungoverned_write`). `execute_write_unsafe/3` and
  `execute_prepared_write_unsafe/3` skip that check and exist for trusted
  tooling and adapter tests only.
  """

  @behaviour Selecto.DB.Adapter
  @behaviour Selecto.DB.WriteAdapter

  alias Selecto.Write.{
    Batch,
    CandidateRequest,
    CandidateState,
    Capabilities,
    Command,
    Error,
    Graph,
    Preview,
    RecordRequest,
    RecordState,
    Result
  }

  alias Selecto.Write.Graph.Materializer
  alias SelectoDBSQLite.WriteCompiler

  @missing_dependency {:adapter_dependency_missing, :exqlite}
  @transaction_depth_key {__MODULE__, :transaction_depth}

  @impl true
  def name, do: :sqlite

  @impl true
  def dialect, do: SelectoDBSQLite.Dialect

  @impl true
  def adapter_contract_version, do: Selecto.DB.Adapter.contract_version()

  @impl true
  def capability(:text_search) do
    %{
      feature: :text_search,
      supported?: true,
      modes: [:websearch, :boolean, :phrase],
      default_mode: :websearch,
      document_type: :text_search_document,
      help: "SQLite FTS5 search with web-style, boolean, and phrase query modes."
    }
  end

  def capability(feature), do: %{feature: feature, supported?: supports?(feature)}

  @impl true
  def normalize_type(type) when is_binary(type) do
    case type
         |> String.trim()
         |> String.downcase()
         |> String.split("(")
         |> hd()
         |> String.trim() do
      value when value in ["integer", "int", "bigint", "smallint", "tinyint", "int2", "int8"] ->
        :integer

      value when value in ["real", "double", "float"] ->
        :float

      value when value in ["numeric", "decimal"] ->
        :decimal

      value when value in ["text", "varchar", "char", "clob"] ->
        :string

      value when value in ["blob", ""] ->
        :binary

      "boolean" ->
        :boolean

      "date" ->
        :date

      value when value in ["datetime", "timestamp"] ->
        :naive_datetime

      "json" ->
        :map

      _unknown ->
        type
    end
  end

  def normalize_type(:fts5), do: :text_search_document
  def normalize_type(type), do: Selecto.TypeSystem.normalize_type(type)

  @impl true
  def type_family(type), do: type |> normalize_type() |> Selecto.TypeFamily.of()

  @impl true
  def normalize_execution_result(%{rows: rows, columns: columns} = result) do
    {:ok, %{result | rows: rows || [], columns: Enum.map(columns || [], &to_string/1)}}
  end

  def normalize_execution_result(result), do: {:error, {:invalid_adapter_result, result}}

  @impl true
  def normalize_error(%Selecto.Error{} = error), do: error

  def normalize_error(%Exqlite.Error{message: message}) when is_binary(message),
    do: sanitized_read_error(message)

  def normalize_error(reason) when is_binary(reason), do: sanitized_read_error(reason)
  def normalize_error(reason), do: Selecto.Error.from_reason(reason)

  # SQLite messages name tables and columns and can quote SQL text. Only a
  # stable category leaves the read path; writes classify constraints below.
  defp sanitized_read_error(message) do
    category =
      cond do
        category = sqlite_constraint_category(message) -> category
        String.starts_with?(message, "CHECK constraint failed") -> :check_violation
        true -> :database_error
      end

    Selecto.Error.query_error("SQLite rejected the statement", nil, [], %{
      adapter: :sqlite,
      category: category
    })
  end

  @impl true
  def connect(connection) when is_reference(connection), do: {:ok, connection}
  def connect(opts) when is_map(opts), do: connect(Map.to_list(opts))

  def connect(opts) when is_list(opts) do
    with :ok <- ensure_exqlite(),
         {:ok, settings} <- connection_settings(opts),
         {:ok, connection} <- Exqlite.Sqlite3.open(settings.database, mode: settings.mode) do
      case configure_connection(connection, settings) do
        :ok ->
          {:ok, connection}

        {:error, _} = error ->
          _ = Exqlite.Sqlite3.close(connection)
          error
      end
    end
  end

  def connect(other), do: {:error, {:invalid_connection_options, other}}

  @impl true
  def disconnect(connection) when is_reference(connection) do
    SelectoDBSQLite.QueryGuard.close(connection)
    Exqlite.Sqlite3.close(connection)
  end

  def disconnect(_connection), do: :ok

  @impl true
  def execute(connection, query, params, opts) do
    with :ok <- ensure_exqlite() do
      connection = unwrap_connection(connection)
      timeout = Keyword.get(opts, :timeout, 5_000)
      params = normalize_params(params || [])

      with {:ok, sqlite_query, params} <-
             query |> normalize_query() |> convert_parameters(params) do
        execute_prepared(connection, sqlite_query, params, timeout)
      end
    end
  end

  @impl true
  def execute_raw(connection, query, params), do: execute(connection, query, params, [])

  @doc "Executes a governed read while preserving caller-owned query_only state."
  @impl true
  def execute_query(connection, query, params, opts),
    do:
      SelectoDBSQLite.QueryGuard.run(connection, fn ->
        execute(connection, query, params, opts)
      end)

  @impl true
  def stream(connection, query, params, opts) do
    with :ok <- ensure_exqlite(),
         {:ok, sqlite_query, params} <-
           query |> normalize_query() |> convert_parameters(normalize_params(params || [])) do
      SelectoDBSQLite.RowStream.build(unwrap_connection(connection), sqlite_query, params, opts)
    end
  end

  @impl true
  def list_tables(connection, opts \\ []),
    do: SelectoDBSQLite.Introspection.list_tables(connection, opts)

  @impl true
  def list_relations(connection, opts \\ []),
    do: SelectoDBSQLite.Introspection.list_relations(connection, opts)

  @impl true
  def introspect_table(connection, table, opts \\ []),
    do: SelectoDBSQLite.Introspection.introspect_table(connection, table, opts)

  @impl true
  def analyze_query(selecto, opts \\ []),
    do: SelectoDBSQLite.Introspection.analyze_query(selecto, opts)

  @impl true
  def validate_connection(connection) do
    case execute(connection, "SELECT 1", [], []) do
      {:ok, _result} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl true
  def connection_info(connection) do
    connection_capabilities(connection) |> Map.put(:adapter, :sqlite)
  end

  @doc "Connected SQLite version, build options, and feature probes."
  def connection_capabilities(connection),
    do: SelectoDBSQLite.RuntimeCapabilities.inspect_connection(connection)

  @doc "Whether the supplied connection supports a feature in this provider."
  def supports?(connection, feature),
    do: Map.get(connection_capabilities(connection).features, feature, false)

  @impl true
  def placeholder(_index), do: "?"

  @impl true
  def quote_identifier(identifier) do
    escaped = identifier |> to_string() |> String.replace("\"", "\"\"")
    "\"#{escaped}\""
  end

  @impl true
  def format_datetime(expression, format) do
    case SelectoDBSQLite.Calendar.format(expression, format) do
      {:ok, sql} -> sql
      {:error, error} -> raise error
    end
  end

  @impl true
  def rollup_literal_order(index), do: [Integer.to_string(index), " asc"]

  @impl true
  def rollup_sort_fix(_connection), do: false

  def transaction(conn, fun), do: transaction(conn, fun, [])

  @impl true
  def transaction(conn, fun, _opts) do
    connection = unwrap_connection(conn)
    depth = transaction_depth_for(connection)

    with {:ok, boundary} <- begin_transaction(connection, depth) do
      put_transaction_depth(connection, depth + 1)
      execute_transaction_fun(connection, fun, depth + 1, boundary)
    end
  end

  @impl true
  def supports?(:json_rowset), do: true
  def supports?(:window_functions), do: true
  def supports?(:cte), do: true
  def supports?(:recursive_cte), do: true
  def supports?(:returning), do: true
  def supports?(:text_search), do: true
  def supports?(:rollup), do: false
  def supports?(:stream), do: true
  def supports?(:schema_introspection), do: true
  def supports?(:query_analysis), do: true
  def supports?(_feature), do: false

  @impl Selecto.DB.WriteAdapter
  def write_capabilities(connection) do
    runtime = connection_capabilities(connection)
    version = runtime.server_version
    returning? = runtime.features.returning

    %{
      protocol_version: Selecto.Write.Capabilities.protocol_version(),
      insert: true,
      update: true,
      upsert:
        SelectoDBSQLite.RuntimeCapabilities.version_at_least?(version, {3, 24, 0}) and
          "OMIT_UPSERT" not in runtime.compile_options,
      delete: true,
      returning: returning?,
      generated_keys: if(returning?, do: :returning, else: false),
      transactions: true,
      atomic_batch: true,
      write_graph: returning?,
      prepared_candidate_state: true,
      typed_insert_admission: runtime.features.schema_introspection,
      typed_insert_precision: false,
      merge: false,
      dialect: :sqlite,
      server_version: version
    }
  end

  @impl Selecto.DB.WriteAdapter
  def preview_write(connection, write, opts \\ [])

  def preview_write(_connection, %Command{} = command, opts),
    do: WriteCompiler.preview(command, opts)

  def preview_write(_connection, %Batch{} = batch, opts), do: WriteCompiler.preview(batch, opts)
  def preview_write(_connection, %Graph{} = graph, opts), do: preview_graph(graph, opts)
  def preview_write(_connection, write, _opts), do: invalid_write_input(write)

  @doc """
  Executes a governed write.

  `opts[:authorization]` must be the `Selecto.Write.Authorization` that the
  governed entry point (`SelectoUpdato`) issued for exactly this command,
  batch, or graph. Without it the write fails with `:ungoverned_write` before
  any statement runs.
  """
  @impl Selecto.DB.WriteAdapter
  def execute_write(connection, write, opts \\ []) do
    with :ok <- Selecto.Write.Authorization.require_for(write, opts) do
      execute_write_unsafe(connection, write, opts)
    end
  end

  @doc """
  Executes a write without domain governance.

  For trusted tooling and adapter tests only; application code writes through
  `SelectoUpdato`.
  """
  @impl Selecto.DB.WriteAdapter
  def execute_write_unsafe(connection, write, opts \\ [])

  def execute_write_unsafe(connection, %Command{} = command, opts) do
    with :ok <- Command.validate(command) do
      with_write_transaction(connection, opts, fn tx ->
        execute_write_command(tx, command, opts)
      end)
    end
  end

  def execute_write_unsafe(connection, %Batch{} = batch, opts) do
    with :ok <- Batch.validate(batch) do
      with_write_transaction(connection, opts, fn tx ->
        Enum.reduce_while(batch.commands, {:ok, []}, fn command, {:ok, results} ->
          case execute_write_command(tx, command, opts) do
            {:ok, result} -> {:cont, {:ok, results ++ [result]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
      end)
    end
  end

  def execute_write_unsafe(connection, %Graph{} = graph, opts) do
    with :ok <- Graph.validate(graph) do
      with_write_transaction(connection, opts, fn tx -> execute_graph(tx, graph, opts) end)
    end
  end

  def execute_write_unsafe(_connection, write, _opts), do: invalid_write_input(write)

  @doc """
  Executes a governed prepared write.

  The preparation must return `{:ok, write, context, authorization}` with the
  governed entry point's authorization for exactly that write; otherwise the
  write fails with `:ungoverned_write` and the transaction rolls back.
  """
  @impl Selecto.DB.WriteAdapter
  def execute_prepared_write(connection, prepare_fun, opts \\ [])

  def execute_prepared_write(connection, prepare_fun, opts) when is_function(prepare_fun, 1) do
    execute_prepared_write_unsafe(
      connection,
      Selecto.Write.Authorization.governed_preparation(prepare_fun),
      opts
    )
  end

  def execute_prepared_write(connection, prepare_fun, opts),
    do: execute_prepared_write_unsafe(connection, prepare_fun, opts)

  @doc """
  Executes a prepared write without domain governance. The preparation returns
  `{:ok, write, context}`.

  For trusted tooling and adapter tests only; application code writes through
  `SelectoUpdato`.
  """
  @impl Selecto.DB.WriteAdapter
  def execute_prepared_write_unsafe(connection, prepare_fun, opts \\ [])

  def execute_prepared_write_unsafe(connection, prepare_fun, opts)
      when is_function(prepare_fun, 1) do
    with_write_transaction(connection, opts, fn tx ->
      loader = &load_prepared_state(tx, &1, opts)

      with {:ok, write, context} <- prepare_fun.(loader),
           :ok <- validate_prepared_write(write),
           :ok <- Capabilities.require(write_capabilities(tx), write) do
        execute_prepared(tx, write, Keyword.put(opts, :context, context))
      else
        {:error, %Error{} = error} -> {:error, error}
        {:error, reason} -> {:error, write_error(:candidate_preparation_failed, reason)}
        other -> {:error, write_error(:candidate_preparation_failed, other)}
      end
    end)
  end

  def execute_prepared_write_unsafe(_connection, prepare_fun, _opts) do
    {:error,
     Error.new(:invalid_preparation, "prepared write requires a one-argument function",
       details: %{actual: prepare_fun}
     )}
  end

  @doc false
  def load_record_state(connection, %RecordRequest{} = request, opts \\ []) do
    with :ok <- valid_record_request(request),
         {:ok, predicate} <-
           WriteCompiler.compile_predicate(request.predicate, context: request.context),
         fields = request.fields |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort(),
         query =
           "SELECT #{Enum.map_join(fields, ", ", &quote_identifier/1)} FROM " <>
             "#{quote_relation(request.relation)} WHERE #{predicate.text}",
         {:ok, result} <- execute(connection, query, predicate.params, opts),
         {:ok, values} <- exactly_one_record(result) do
      {:ok, %RecordState{values: values, complete?: true, protection: :locked}}
    end
  end

  @doc false
  def load_candidate_state(connection, %CandidateRequest{} = request, opts \\ []) do
    with :ok <- valid_candidate_request(request),
         {:ok, predicate} <-
           WriteCompiler.compile_predicate(request.parent_command.predicate,
             context: request.context
           ),
         parent_query =
           "SELECT #{quote_identifier(request.parent_key)} FROM " <>
             "#{quote_relation(request.parent_command.relation)} WHERE #{predicate.text}",
         {:ok, parent_result} <- execute(connection, parent_query, predicate.params, opts),
         {:ok, parent_id} <- exactly_one_parent(parent_result),
         fields =
           (request.fields ++ request.identity_fields)
           |> Enum.map(&to_string/1)
           |> Enum.uniq()
           |> Enum.sort(),
         child_query =
           "SELECT #{Enum.map_join(fields, ", ", &quote_identifier/1)} FROM " <>
             "#{quote_relation(request.child_relation)} WHERE #{quote_identifier(request.child_key)} = ? " <>
             "ORDER BY #{Enum.map_join(request.identity_fields, ", ", &quote_identifier/1)} LIMIT ?",
         {:ok, child_result} <-
           execute(connection, child_query, [parent_id, request.max_rows + 1], opts),
         :ok <- candidate_bound(child_result, request.max_rows) do
      {:ok,
       %CandidateState{rows: result_rows(child_result), complete?: true, protection: :locked}}
    end
  end

  defp load_prepared_state(connection, %RecordRequest{} = request, opts),
    do: load_record_state(connection, request, opts)

  defp load_prepared_state(connection, %CandidateRequest{} = request, opts),
    do: load_candidate_state(connection, request, opts)

  defp load_prepared_state(_connection, request, _opts),
    do:
      {:error,
       Error.new(:invalid_preparation, "unsupported prepared-state request",
         details: %{actual: request}
       )}

  defp preview_graph(%Graph{} = graph, opts) do
    graph.nodes
    |> Enum.reduce_while({:ok, [], %{}}, fn node, {:ok, statements, results} ->
      with {:ok, materialized} <- Materializer.materialize_node(node, results),
           {:ok, node_statements} <- preview_graph_node(materialized, opts) do
        next_results = Map.merge(results, Materializer.symbolic_results(materialized))
        {:cont, {:ok, statements ++ node_statements, next_results}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, statements, _results} ->
        {:ok,
         %Preview{
           statements: statements,
           metadata: %{
             dialect: :sqlite,
             atomic?: true,
             graph?: true,
             strategy: :ordered_fallback,
             merge: false,
             merge_reason: :unsupported_by_sqlite
           }
         }}

      error ->
        error
    end
  end

  defp preview_graph_node(node, opts) do
    row_results =
      node
      |> Materializer.symbolic_results()
      |> Map.new(fn {{_node_id, row_id}, result} -> {row_id, result} end)

    with {:ok, cleanup} <- Materializer.delete_missing_command(node, row_results) do
      commands = Enum.map(node.rows, & &1.command)
      commands = if cleanup, do: commands ++ [cleanup], else: commands

      Enum.reduce_while(commands, {:ok, []}, fn command, {:ok, statements} ->
        case WriteCompiler.compile(command, opts) do
          {:ok, statement} -> {:cont, {:ok, statements ++ [statement]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp execute_graph(connection, graph, opts) do
    graph.nodes
    |> Enum.reduce_while({:ok, %{}, 0, []}, fn node, {:ok, results, affected_rows, strategies} ->
      with {:ok, materialized} <- Materializer.materialize_node(node, results),
           {:ok, node_results, node_affected} <-
             execute_graph_node(connection, materialized, opts) do
        next_results =
          Map.merge(
            results,
            Map.new(node_results, fn {row_id, result} -> {{node.id, row_id}, result} end)
          )

        {:cont,
         {:ok, next_results, affected_rows + node_affected,
          strategies ++ [{node.id, :ordered_fallback}]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results, affected_rows, strategies} ->
        {:ok,
         %Result{
           operation: :graph,
           affected_rows: affected_rows,
           rows: Materializer.root_rows(graph, results),
           metadata:
             %{
               dialect: :sqlite,
               atomic?: true,
               node_strategies: Map.new(strategies)
             }
             |> Map.merge(Materializer.outcome_metadata(graph, results))
         }}

      error ->
        error
    end
  end

  defp execute_graph_node(connection, node, opts) do
    with {:ok, row_results, affected_rows} <- execute_graph_rows(connection, node.rows, opts),
         {:ok, cleanup} <- Materializer.delete_missing_command(node, row_results),
         {:ok, cleanup_affected} <- execute_graph_cleanup(connection, cleanup, opts) do
      {:ok, row_results, affected_rows + cleanup_affected}
    end
  end

  defp execute_graph_rows(connection, rows, opts) do
    Enum.reduce_while(rows, {:ok, %{}, 0}, fn row, {:ok, results, affected_rows} ->
      case execute_write_command(connection, row.command, opts) do
        {:ok, result} ->
          {:cont, {:ok, Map.put(results, row.id, result), affected_rows + result.affected_rows}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp execute_graph_cleanup(_connection, nil, _opts), do: {:ok, 0}

  defp execute_graph_cleanup(connection, command, opts) do
    case execute_write_command(connection, command, opts) do
      {:ok, result} -> {:ok, result.affected_rows}
      {:error, _} = error -> error
    end
  end

  defp execute_write_command(connection, command, opts) do
    with :ok <- SelectoDBSQLite.InsertAdmission.enforce(connection, command, opts),
         {:ok, statement} <- WriteCompiler.compile(command, opts),
         {:ok, query_result} <- execute(connection, statement.text, statement.params, opts),
         {:ok, affected_rows} <- enforce_cardinality(command, query_result) do
      {:ok,
       %Result{
         operation: command.operation,
         affected_rows: affected_rows,
         rows: result_rows(query_result),
         metadata: %{dialect: :sqlite}
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, write_error(:execution_failed, reason)}
    end
  end

  defp enforce_cardinality(%Command{expected_cardinality: expected}, result) do
    affected_rows = Map.get(result, :num_rows, length(Map.get(result, :rows, [])))

    if cardinality_matches?(affected_rows, expected) do
      {:ok, affected_rows}
    else
      {:error,
       Error.new(:cardinality_mismatch, "write affected an unexpected number of rows",
         details: %{expected: expected, actual: affected_rows}
       )}
    end
  end

  defp cardinality_matches?(count, {:exactly, expected}), do: count == expected
  defp cardinality_matches?(count, {:at_most, expected}), do: count <= expected
  defp cardinality_matches?(count, {:at_least, expected}), do: count >= expected
  defp cardinality_matches?(count, {:between, minimum, maximum}), do: count in minimum..maximum
  defp cardinality_matches?(_count, :many), do: true

  defp result_rows(%{columns: ["Count"]}), do: []

  defp result_rows(%{rows: rows, columns: columns}) do
    Enum.map(rows, fn row -> Map.new(Enum.zip(columns, row)) end)
  end

  defp validate_prepared_write(%Command{} = command), do: Command.validate(command)
  defp validate_prepared_write(%Batch{} = batch), do: Batch.validate(batch)
  defp validate_prepared_write(%Graph{} = graph), do: Graph.validate(graph)

  defp validate_prepared_write(other),
    do: invalid_write_input(other) |> elem(1) |> then(&{:error, &1})

  defp execute_prepared(connection, %Command{} = command, opts),
    do: execute_write_command(connection, command, opts)

  defp execute_prepared(connection, %Batch{} = batch, opts) do
    Enum.reduce_while(batch.commands, {:ok, []}, fn command, {:ok, results} ->
      case execute_write_command(connection, command, opts) do
        {:ok, result} -> {:cont, {:ok, results ++ [result]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp execute_prepared(connection, %Graph{} = graph, opts),
    do: execute_graph(connection, graph, opts)

  defp valid_record_request(%RecordRequest{
         operation: operation,
         relation: relation,
         predicate: predicate,
         fields: fields
       }) do
    if operation in [:update, "update"] and not is_nil(predicate) and fields != [] and
         valid_identifier?(relation) and Enum.all?(fields, &valid_identifier?/1),
       do: :ok,
       else: {:error, Error.new(:invalid_record_request, "record-state request is invalid")}
  end

  defp valid_candidate_request(%CandidateRequest{} = request) do
    identifiers =
      [
        request.parent_command.relation,
        request.parent_key,
        request.child_relation,
        request.child_key
      ] ++
        request.identity_fields ++ request.fields

    if request.parent_command.operation in [:update, :delete] and
         not is_nil(request.parent_command.predicate) and request.identity_fields != [] and
         is_integer(request.max_rows) and request.max_rows in 1..1_000 and
         Enum.all?(identifiers, &valid_identifier?/1),
       do: :ok,
       else: {:error, Error.new(:invalid_candidate_request, "candidate-state request is invalid")}
  end

  defp valid_identifier?(value) when is_atom(value), do: not is_nil(value)
  defp valid_identifier?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_identifier?(_value), do: false

  defp exactly_one_parent(%{rows: [[id]]}), do: {:ok, id}

  defp exactly_one_parent(%{rows: rows}) do
    {:error,
     Error.new(:cardinality_mismatch, "candidate parent matched an unexpected number of rows",
       details: %{expected: 1, actual: length(rows)}
     )}
  end

  defp exactly_one_record(%{rows: [_], columns: _} = result),
    do: {:ok, result_rows(result) |> hd()}

  defp exactly_one_record(%{rows: rows}) do
    {:error,
     Error.new(:cardinality_mismatch, "record candidate matched an unexpected number of rows",
       details: %{expected: 1, actual: length(rows)}
     )}
  end

  defp candidate_bound(%{rows: rows}, max_rows) when length(rows) <= max_rows, do: :ok

  defp candidate_bound(%{rows: rows}, max_rows) do
    {:error,
     Error.new(:candidate_state_limit_exceeded, "candidate state exceeds its row bound",
       details: %{max_rows: max_rows, observed_at_least: length(rows)}
     )}
  end

  defp quote_relation(relation) do
    relation
    |> to_string()
    |> String.split(".")
    |> Enum.map_join(".", &quote_identifier/1)
  end

  defp invalid_write_input(write) do
    {:error,
     Error.new(:invalid_command, "expected a portable write command, batch, or graph",
       details: %{actual: write}
     )}
  end

  defp with_write_transaction(connection, opts, fun) do
    case transaction(connection, fun, opts) do
      {:ok, result} -> {:ok, result}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, write_error(:transaction_failed, reason)}
    end
  end

  defp write_error(type, %Exqlite.Error{message: message} = reason) when is_binary(message) do
    native_constraint_error(type, message, reason)
  end

  defp write_error(type, message) when is_binary(message) do
    native_constraint_error(type, message, message)
  end

  defp write_error(type, reason),
    do: Error.adapter_failure(type, :sqlite, reason, "SQLite write failed")

  defp native_constraint_error(type, message, reason) do
    case sqlite_constraint_category(message) do
      nil ->
        Error.adapter_failure(type, :sqlite, reason, "SQLite write failed")

      category ->
        Error.new(:native_constraint_violation, "SQLite constraint rejected write",
          details: %{
            adapter: :sqlite,
            write_stage: type,
            category: category,
            column: sqlite_constraint_column(message),
            recoverable?: true
          }
        )
    end
  end

  defp sqlite_constraint_category("UNIQUE constraint failed:" <> _rest), do: :unique_violation

  defp sqlite_constraint_category("FOREIGN KEY constraint failed" <> _rest),
    do: :foreign_key_violation

  defp sqlite_constraint_category("NOT NULL constraint failed:" <> _rest), do: :not_null_violation
  defp sqlite_constraint_category(_message), do: nil

  defp sqlite_constraint_column(message) do
    case String.split(message, ": ", parts: 2) do
      [_prefix, column] when column != "" -> column
      _ -> nil
    end
  end

  defp begin_transaction(connection, 0) do
    case execute(connection, "BEGIN IMMEDIATE", [], []) do
      {:ok, _} ->
        {:ok, :transaction}

      {:error, reason} ->
        # Older Exqlite releases do not expose sqlite3_get_autocommit. SQLite's
        # specific nested-BEGIN refusal establishes caller transaction ownership
        # without committing or rolling it back. Other failures stay failures.
        if nested_begin_error?(reason),
          do: begin_savepoint(connection, 1),
          else: {:error, reason}
    end
  end

  defp begin_transaction(connection, depth), do: begin_savepoint(connection, depth + 1)

  defp nested_begin_error?(%Exqlite.Error{message: message}), do: nested_begin_error?(message)
  defp nested_begin_error?("cannot start a transaction within a transaction"), do: true
  defp nested_begin_error?(_reason), do: false

  defp begin_savepoint(connection, depth) do
    name = "selecto_sp_#{depth}_#{System.unique_integer([:positive])}"

    case execute(connection, "SAVEPOINT #{name}", [], []) do
      {:ok, _} -> {:ok, {:savepoint, name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_transaction_fun(connection, fun, depth, boundary) do
    case fun.(connection) do
      {:error, reason} ->
        rollback(connection, boundary, reason)

      {:ok, result} ->
        finish_commit(connection, boundary, result)

      result ->
        finish_commit(connection, boundary, result)
    end
  rescue
    exception -> rollback(connection, boundary, {:transaction_exception, exception})
  catch
    kind, reason -> rollback(connection, boundary, {kind, reason})
  after
    put_transaction_depth(connection, max(depth - 1, 0))
  end

  defp finish_commit(connection, boundary, result) do
    statement =
      case boundary do
        :transaction -> "COMMIT"
        {:savepoint, name} -> "RELEASE SAVEPOINT #{name}"
      end

    case execute(connection, statement, [], []) do
      {:ok, _} -> {:ok, result}
      {:error, reason} -> rollback(connection, boundary, reason)
    end
  end

  defp rollback(connection, :transaction, reason) do
    _ = execute(connection, "ROLLBACK", [], [])
    {:error, reason}
  end

  defp rollback(connection, {:savepoint, savepoint}, reason) do
    _ = execute(connection, "ROLLBACK TO SAVEPOINT #{savepoint}", [], [])
    _ = execute(connection, "RELEASE SAVEPOINT #{savepoint}", [], [])
    {:error, reason}
  end

  defp transaction_depth_for(connection),
    do: Process.get(@transaction_depth_key, %{}) |> Map.get(connection, 0)

  defp put_transaction_depth(connection, depth) do
    depths = Process.get(@transaction_depth_key, %{})

    depths =
      if depth <= 0, do: Map.delete(depths, connection), else: Map.put(depths, connection, depth)

    Process.put(@transaction_depth_key, depths)
    :ok
  end

  defp execute_prepared(connection, query, params, timeout) do
    case Exqlite.Sqlite3.prepare(connection, query) do
      {:ok, statement} ->
        try do
          with :ok <- Exqlite.Sqlite3.bind(statement, params),
               {:ok, columns} <- Exqlite.Sqlite3.columns(connection, statement),
               {:ok, rows} <- fetch_all(connection, statement, timeout),
               {:ok, num_rows} <- mutation_count(connection, query, rows) do
            {:ok,
             %{
               columns: Enum.map(columns || [], &to_string/1),
               rows: rows,
               num_rows: num_rows,
               metadata: %{}
             }}
          end
        after
          Exqlite.Sqlite3.release(connection, statement)
        end

      {:error, _} = error ->
        error
    end
  end

  defp mutation_count(connection, query, rows) do
    if mutation_query?(query) do
      Exqlite.Sqlite3.changes(connection)
    else
      {:ok, length(rows)}
    end
  end

  defp mutation_query?(query) do
    query
    |> String.trim_leading()
    |> String.downcase()
    |> then(
      &Enum.any?(["insert", "update", "delete", "replace"], fn prefix ->
        String.starts_with?(&1, prefix)
      end)
    )
  end

  defp connection_settings(opts) do
    if Keyword.keyword?(opts) do
      allowed = [
        :database,
        :mode,
        :foreign_keys,
        :busy_timeout,
        :journal_mode,
        :cache_size,
        :synchronous,
        :temp_store,
        :extensions
      ]

      case Enum.find(opts, fn {key, _value} -> key not in allowed end) do
        nil -> validate_connection_settings(opts)
        {key, value} -> {:error, {:invalid_connection_option, key, value}}
      end
    else
      {:error, {:invalid_connection_options, opts}}
    end
  end

  defp validate_connection_settings(opts) do
    database = Keyword.get(opts, :database, ":memory:")
    mode = Keyword.get(opts, :mode, [:readwrite, :create])
    extensions = Keyword.get(opts, :extensions, [])

    with :ok <- validate_database(database),
         :ok <- validate_open_mode(mode),
         :ok <- validate_extensions(extensions),
         {:ok, pragmas} <- connection_pragmas(opts) do
      {:ok, %{database: database, mode: mode, extensions: extensions, pragmas: pragmas}}
    end
  end

  defp validate_database(database) when is_binary(database) and byte_size(database) > 0 do
    if String.contains?(database, <<0>>),
      do: {:error, {:invalid_connection_option, :database, database}},
      else: :ok
  end

  defp validate_database(database),
    do: {:error, {:invalid_connection_option, :database, database}}

  defp validate_open_mode(mode) when mode in [:readwrite, :readonly, :create], do: :ok

  defp validate_open_mode(modes) when is_list(modes) and modes != [] do
    valid? =
      Enum.all?(modes, &(&1 in [:readwrite, :readonly, :create, :nomutex])) and
        Enum.any?(modes, &(&1 in [:readwrite, :readonly, :create])) and
        not (:readwrite in modes and :readonly in modes) and
        not (:readonly in modes and :create in modes)

    if valid?, do: :ok, else: {:error, {:invalid_connection_option, :mode, modes}}
  end

  defp validate_open_mode(mode), do: {:error, {:invalid_connection_option, :mode, mode}}

  defp validate_extensions(extensions) when is_list(extensions) do
    Enum.reduce_while(extensions, :ok, fn path, :ok ->
      if is_binary(path) and byte_size(path) > 0 and not String.contains?(path, <<0>>) do
        if File.regular?(path),
          do: {:cont, :ok},
          else: {:halt, {:error, {:sqlite_extension_not_found, path}}}
      else
        {:halt, {:error, {:invalid_connection_option, :extensions, extensions}}}
      end
    end)
  end

  defp validate_extensions(value), do: {:error, {:invalid_connection_option, :extensions, value}}

  defp connection_pragmas(opts) do
    opts = Keyword.put_new(opts, :foreign_keys, :on)

    [:foreign_keys, :busy_timeout, :journal_mode, :cache_size, :synchronous, :temp_store]
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, pragmas} ->
      if Keyword.has_key?(opts, key) do
        case pragma_value(key, Keyword.fetch!(opts, key)) do
          {:ok, value} -> {:cont, {:ok, pragmas ++ [{key, value}]}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, pragmas}}
      end
    end)
  end

  defp pragma_value(:foreign_keys, value) when value in [:on, true, 1, "on", "ON"],
    do: {:ok, "ON"}

  defp pragma_value(:foreign_keys, value) when value in [:off, false, 0, "off", "OFF"],
    do: {:ok, "OFF"}

  defp pragma_value(:busy_timeout, value) when is_integer(value) and value in 0..2_147_483_647,
    do: {:ok, Integer.to_string(value)}

  defp pragma_value(:cache_size, value)
       when is_integer(value) and value in -2_147_483_648..2_147_483_647,
       do: {:ok, Integer.to_string(value)}

  defp pragma_value(key, value) when key in [:journal_mode, :synchronous, :temp_store] do
    allowed =
      case key do
        :journal_mode -> ["DELETE", "TRUNCATE", "PERSIST", "MEMORY", "WAL", "OFF"]
        :synchronous -> ["OFF", "NORMAL", "FULL", "EXTRA", "0", "1", "2", "3"]
        :temp_store -> ["DEFAULT", "FILE", "MEMORY", "0", "1", "2"]
      end

    normalized =
      if is_atom(value) or is_binary(value) or is_integer(value),
        do: value |> to_string() |> String.upcase(),
        else: nil

    if normalized in allowed,
      do: {:ok, normalized},
      else: {:error, {:invalid_connection_option, key, value}}
  end

  defp pragma_value(:busy_timeout, value), do: {:error, {:invalid_busy_timeout, value}}
  defp pragma_value(key, value), do: {:error, {:invalid_connection_option, key, value}}

  defp configure_connection(connection, settings) do
    with :ok <- configure_pragmas(connection, settings.pragmas),
         :ok <- load_extensions(connection, settings.extensions) do
      :ok
    end
  end

  defp configure_pragmas(connection, pragmas) do
    Enum.reduce_while(pragmas, :ok, fn {key, value}, :ok ->
      case Exqlite.Sqlite3.execute(connection, "PRAGMA #{key} = #{value}") do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp load_extensions(_connection, []), do: :ok

  defp load_extensions(connection, extensions) do
    with :ok <- Exqlite.Sqlite3.enable_load_extension(connection, true) do
      try do
        Enum.reduce_while(extensions, :ok, fn path, :ok ->
          case execute(connection, "SELECT load_extension(?)", [path], []) do
            {:ok, _result} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:sqlite_extension_load_failed, path, reason}}}
          end
        end)
      after
        Exqlite.Sqlite3.enable_load_extension(connection, false)
      end
    end
  end

  defp ensure_exqlite do
    if Code.ensure_loaded?(Exqlite.Sqlite3), do: :ok, else: {:error, @missing_dependency}
  end

  defp unwrap_connection(%{connection: connection}), do: connection
  defp unwrap_connection(connection), do: connection

  defp normalize_query(query) when is_binary(query), do: query
  defp normalize_query(query), do: IO.iodata_to_binary(query)

  defp normalize_params(params) when is_list(params), do: Enum.map(params, &normalize_param/1)
  defp normalize_params(params), do: params

  defp normalize_param(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp normalize_param(true), do: 1
  defp normalize_param(false), do: 0
  defp normalize_param(value), do: value

  defp fetch_all(db, statement, timeout) do
    task = Task.async(fn -> fetch_rows(db, statement, []) end)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      nil ->
        _ = Exqlite.Sqlite3.interrupt(db)
        _ = Task.shutdown(task)
        {:error, :timeout}
    end
  end

  defp fetch_rows(db, statement, acc) do
    case Exqlite.Sqlite3.step(db, statement) do
      {:row, row} -> fetch_rows(db, statement, [row | acc])
      :done -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Convert PostgreSQL-style $1, $2 to SQLite's numbered ?1, ?2, which bind by
  # number, so reordered and repeated placeholders keep their values. Only
  # placeholders outside quoted text and comments are rewritten, each by its
  # full number.
  @doc false
  def convert_parameters(query, []), do: {:ok, query, []}

  def convert_parameters(query, params) do
    {sqlite_query, indexes, bare?} = scan_placeholders(query, [], [], false, nil)

    cond do
      indexes == [] ->
        {:ok, query, params}

      bare? ->
        placeholder_error("numbered and positional placeholders cannot be mixed")

      Enum.any?(indexes, &(&1 < 1 or &1 > length(params))) ->
        placeholder_error("numbered placeholder has no matching parameter")

      true ->
        {:ok, sqlite_query, params}
    end
  end

  defp placeholder_error(message) do
    {:error, Selecto.Error.validation_error(message, %{adapter: :sqlite, option: :params})}
  end

  defguardp identifier_byte?(byte)
            when is_integer(byte) and
                   (byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in [?_, ?$] or
                      byte >= 0x80)

  defp scan_placeholders(<<>>, acc, indexes, bare?, _previous),
    do: {IO.iodata_to_binary(acc), Enum.reverse(indexes), bare?}

  defp scan_placeholders(<<quote, rest::binary>>, acc, indexes, bare?, _previous)
       when quote in [?', ?", ?`] do
    {quoted, rest} = take_quoted(rest, quote, <<quote>>)
    scan_placeholders(rest, [acc, quoted], indexes, bare?, quote)
  end

  defp scan_placeholders(<<"[", rest::binary>>, acc, indexes, bare?, _previous) do
    {identifier, rest} = take_until(rest, "]", "[")
    scan_placeholders(rest, [acc, identifier], indexes, bare?, ?])
  end

  defp scan_placeholders(<<"/*", rest::binary>>, acc, indexes, bare?, _previous) do
    {comment, rest} = take_until(rest, "*/", "/*")
    scan_placeholders(rest, [acc, comment], indexes, bare?, ?/)
  end

  defp scan_placeholders(<<"--", rest::binary>>, acc, indexes, bare?, _previous) do
    {comment, rest} = take_until(rest, "\n", "--")
    scan_placeholders(rest, [acc, comment], indexes, bare?, ?\n)
  end

  defp scan_placeholders(<<"$", digit, _::binary>> = text, acc, indexes, bare?, previous)
       when digit in ?0..?9 and not identifier_byte?(previous) do
    <<"$", rest::binary>> = text
    {digits, rest} = take_digits(rest, "")
    index = String.to_integer(digits)

    scan_placeholders(rest, [acc, "?", Integer.to_string(index)], [index | indexes], bare?, ?0)
  end

  defp scan_placeholders(<<"?", rest::binary>>, acc, indexes, _bare?, _previous),
    do: scan_placeholders(rest, [acc, "?"], indexes, true, ??)

  defp scan_placeholders(<<byte, rest::binary>>, acc, indexes, bare?, _previous),
    do: scan_placeholders(rest, [acc, byte], indexes, bare?, byte)

  # SQLite has no backslash escapes: a quoted run ends at a closing quote that
  # is not doubled.
  defp take_quoted(<<>>, _quote, acc), do: {acc, ""}

  defp take_quoted(<<quote, quote, rest::binary>>, quote, acc),
    do: take_quoted(rest, quote, <<acc::binary, quote, quote>>)

  defp take_quoted(<<quote, rest::binary>>, quote, acc), do: {<<acc::binary, quote>>, rest}

  defp take_quoted(<<byte, rest::binary>>, quote, acc),
    do: take_quoted(rest, quote, <<acc::binary, byte>>)

  defp take_until(text, terminator, prefix) do
    case :binary.split(text, terminator) do
      [body, rest] -> {prefix <> body <> terminator, rest}
      [body] -> {prefix <> body, ""}
    end
  end

  defp take_digits(<<digit, rest::binary>>, acc) when digit in ?0..?9,
    do: take_digits(rest, <<acc::binary, digit>>)

  defp take_digits(rest, acc), do: {acc, rest}
end
